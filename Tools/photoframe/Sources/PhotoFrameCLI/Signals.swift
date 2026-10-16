import Darwin
import Dispatch
import Foundation

extension InterruptMonitor {
    /// 把 SIGINT（Ctrl-C）和 SIGTERM 接到这个监视器上。只有可执行文件调用。
    ///
    /// - 第一次信号：有命令登记了中断处理（导出正在进行）时调用 `trigger()`，命令取消任务、等它们停下、清理临时目录后以 130 退出；
    ///   没有登记处理时没有需要清理的东西，直接以 130 退出。
    /// - 第二次信号：立即以 130 退出（残留的临时目录由下次导出时按 D-55 清理）。
    ///
    /// 回调在后台队列上执行，所以这个函数不能放在 main.swift 的顶层代码里（那里的闭包属于 MainActor，Swift 6 会在
    /// 后台队列调用时触发隔离检查而崩溃）。
    public func installSignalHandlers() -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [self] in
                if isTriggered || !hasHandlers {
                    _exit(PhotoFrameExitCode.interrupted.rawValue)
                }
                FileHandle.standardError.write(Data("\n正在取消…（再按一次 Ctrl-C 立即退出）\n".utf8))
                trigger()
            }
            source.resume()
            return source
        }
    }
}
