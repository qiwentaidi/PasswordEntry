# Password Entry

Password Entry 是一个只支持 macOS 的本地密码管理器原型，由 SwiftUI 桌面端和 Chrome Manifest V3 扩展组成。桌面端持有保险库、解锁状态和 TOTP 生成；扩展只负责识别网页表单、显示保存/填充提示，并通过 Native Messaging 调用桌面端。

## 构建桌面端

```bash
./scripts/build-macos.sh
open "dist/Password Entry.app"
```

构建脚本会同时生成：

- `dist/Password Entry.app`：macOS 桌面端
- `dist/password-entry-extension.zip`：Chrome Manifest V3 扩展源码包
- `native-host/build/password-entry-native-host`：Native Messaging Host

也可以使用一键安装脚本将桌面端复制到 `~/Applications`：

```bash
./scripts/install-macos.sh EXTENSION_ID
./scripts/verify-macos.sh
```

Chrome 扩展仍需要在 `chrome://extensions` 中开启开发者模式并加载解压后的扩展目录；Chrome 不允许普通本地脚本静默安装未上架扩展。加载完成后，将扩展 ID 传给 `install-macos.sh`，脚本会安装并校验 Native Messaging manifest。

桌面端首次打开时设置至少 12 个字符的主密码。保险库保存在 `~/Library/Application Support/Password Entry/vault.json`，使用随机设备密钥、PBKDF2-SHA256 和 AES-256-GCM 加密。设备密钥保存在 macOS Keychain。

## 安装 Chrome 扩展

1. 打开 `chrome://extensions` 并开启开发者模式。
2. 选择“加载未打包的扩展程序”，选择本项目目录。
3. 记录扩展 ID。
4. 安装 Native Messaging Host：

```bash
./native-host/install.sh YOUR_EXTENSION_ID
```

5. 打开 `dist/Password Entry.app` 并解锁桌面端。

## 支持的流程

- 登录页匹配到已有条目时显示“填充登录”提示。
- 登录表单提交后，未保存的网站显示“是否保存此登录信息”，已有账号显示“是否更新此登录信息”。只有点击保存或更新后才把登录信息发送到本机桌面端。
- 保存登录时会一并缓存网站 favicon；桌面端列表、详情页和扩展弹窗都会显示该图标。
- TOTP 密钥只由桌面端保存和生成；带 TOTP 的登录项在登录页显示“Touch ID 登录”，验证后填入账号密码并继续，进入 MFA 页面后自动填入当前验证码。没有 TOTP 的登录项仍使用普通“填充登录”。
- 插件不会在本地保存保险库，也不会把密码发送到网络。
- 桌面端常驻 macOS 菜单栏；关闭主窗口不会停止 Native Messaging。菜单栏中的“设置”可以管理登录时自动启动。
- 插件只读同步桌面端的解锁状态，不提供锁定或解锁入口；锁定操作统一在桌面端完成。
- 默认按精确主机名或其子域名匹配，填充需要用户点击。
- 同一网站、同一用户名再次通过保存提示保存时会更新已有密码，不会无限创建重复登录项。

### 分享链接 MVP

分享功能默认使用本地开发 API `http://127.0.0.1:8787`。启动服务：

```bash
python3 share-api/server.py
```

桌面端会在客户端生成 AES-GCM 加密副本、查看密钥和撤销密钥；云端 SQLite 只保存加密副本和分享生命周期信息。部署到 HTTPS 地址后，在桌面端“设置 → 分享服务”中填写 API 地址，例如 `https://share.example.com`。

链接中的查看密钥位于 URL fragment（`#` 后），服务端不会收到它。当前 MVP 支持登录项、默认 7 天过期、复制链接和手动撤销；邮箱限制、附件和单次查看尚未加入。

### 阿里云 RAM VMFA

条目的域名只填写 `signin.aliyun.com`，不要把完整 callback URL 存进去。首次绑定或更换 VMFA 时，在阿里云绑定页面复制手动密钥（或 `otpauth://` 链接）到桌面端条目的 TOTP 字段，然后用同一个密钥重新添加到 Google Authenticator。桌面端只有在 Touch ID/本机身份验证通过后才会生成或复制验证码；验证码按 30 秒周期刷新并显示剩余秒数。

如果旧 VMFA 已经绑定且无法看到密钥，阿里云不会回显原始密钥。保留手机里的旧验证码，先在 RAM 安全信息中解绑，再立即重新绑定并记录新密钥；没有自助解绑权限时需要 RAM 管理员操作。不要把真实密钥或 Google Authenticator 导出二维码上传到在线解析服务。

## 本地验证

```bash
swift run PasswordEntrySmoke
node --check src/background.js
node --check src/content.js
node --check src/popup.js
./scripts/verify-macos.sh
```

`PasswordEntrySmoke` 会验证保险库加解密、错误密码拒绝、子域名匹配和 RFC 6238 TOTP 测试向量。

要做浏览器端回归测试，可在一个终端启动内置测试页：

```bash
./scripts/serve-test-page.sh 8765
```

然后在 Chrome 打开 `http://127.0.0.1:8765/`，验证匹配提示、账号密码填充、登录保存提示和 Touch ID 验证码填充。测试页只使用虚拟账号和密码，不要在真实云账号页面中粘贴测试密钥。
