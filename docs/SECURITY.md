# 安全策略 / Security Policy

[中文](#中文) · [English](#english)

---

## 中文

### 支持的版本

项目处于规范和早期开发阶段，还没有正式发布的版本。安全修复只针对 `main` 分支；发布 Alpha 版本后，这里会列出仍在维护的版本。

### 报告漏洞

**请不要在公开的 Issue、Pull Request 或讨论区里报告安全问题。**

请通过 GitHub 的私密漏洞报告提交：

1. 打开仓库的 [Security 页面](https://github.com/Jeremy233/another_photo_frame/security)；
2. 点击 **Report a vulnerability**，填写 Security Advisory 表单。

<!-- TODO: 如需备用联系方式（例如安全邮箱），在这里补充。 -->

报告里请尽量包含：

- 受影响的模块、文件或版本（commit）；
- 复现步骤或概念验证；
- 可能造成的影响。

如果复现需要特定的图片或预设文件，请只提供能触发问题的最小文件，不要附带个人照片。

### 处理流程

- 我们会尽快确认收到报告，并在私密的 Advisory 里和你沟通进展。
- 确认问题后会修复并发布说明；如果你愿意，会在说明中致谢。
- 这是个人维护的开源项目，没有漏洞赏金。

### 适用范围

AnotherPhotoFrame 只在本地运行，但会处理来自外部的文件，因此以下问题尤其值得报告：

- 解析图片、ICC 配置文件、元数据时的崩溃或内存安全问题；
- 预设文件（ZIP）的路径穿越、解压炸弹、超大条目等问题（规范 §8.3）；
- SVG 素材绕过限制，执行脚本或加载外部、远程资源（规范 D-09）；
- 本地 MCP / CLI 接口越权读写文件，或被暴露到本机以外（规范 §11.4）；
- 导出文件意外泄露 GPS 等隐私元数据（规范 §12.3）。

---

## English

### Supported versions

The project is in the specification and early development stage and has no released versions yet. Security fixes target the `main` branch only; once Alpha builds are published, the maintained versions will be listed here.

### Reporting a vulnerability

**Please do not report security issues in public issues, pull requests or discussions.**

Report them privately through GitHub:

1. Open the repository's [Security page](https://github.com/Jeremy233/another_photo_frame/security);
2. Click **Report a vulnerability** and fill in the security advisory form.

<!-- TODO: add a fallback contact (such as a security email) here if needed. -->

Please include, where possible:

- the affected module, file or version (commit);
- steps to reproduce or a proof of concept;
- the potential impact.

If reproducing the issue needs a specific image or preset file, please send only the smallest file that triggers it, not personal photos.

### What happens next

- We will acknowledge the report as soon as we can and keep you updated in the private advisory.
- Once confirmed, the issue will be fixed and disclosed, with credit to you if you wish.
- This is a personally maintained open-source project; there is no bug bounty.

### Scope

AnotherPhotoFrame runs locally, but it processes files from outside, so these are especially worth reporting:

- crashes or memory-safety issues when parsing images, ICC profiles or metadata;
- path traversal, decompression bombs or oversized entries in preset (ZIP) files (spec §8.3);
- SVG assets that bypass the restrictions to run scripts or load external or remote resources (spec D-09);
- the local MCP / CLI interfaces reading or writing files beyond what they should, or being exposed beyond the local machine (spec §11.4);
- exported files unexpectedly leaking private metadata such as GPS (spec §12.3).
