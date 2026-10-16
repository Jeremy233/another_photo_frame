# photoframe

命令行工具（规范 §11.3）。命令、参数、退出码和 JSON 格式见 [docs/CLI.md](../../docs/CLI.md)。

| 目录 | 内容 |
|---|---|
| `Sources/PhotoFrameCLI` | 命令（swift-argument-parser）、JSON 输出格式、退出码、进度、信号处理 |
| `Sources/photoframe` | 可执行文件入口：安装 SIGINT / SIGTERM 处理，运行命令，返回退出码 |
| `Tests/PhotoFrameCLITests` | 参数解析、退出码、各命令的 JSON、端到端导出（代码合成的图片）、子进程测试 |

服务来自 `LocalPhotoFrameService.makeDefault()`（PhotoFrameApplication），与 GUI、MCP 共用。

```bash
swift build --scratch-path "$TMPDIR/photoframe-build"
swift test --scratch-path "$TMPDIR/photoframe-build"
```
