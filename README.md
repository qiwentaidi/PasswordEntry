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
- 桌面端常驻 macOS 菜单栏；关闭主窗口不会停止 Native Messaging。主窗口工具栏和菜单栏中的“设置”可以管理分享服务地址与登录时自动启动。
- 插件只读同步桌面端的解锁状态，不提供锁定或解锁入口；锁定操作统一在桌面端完成。
- 默认按完整网站 origin（协议、主机名和端口）精确匹配，填充需要用户点击。
- 同一网站、同一用户名再次通过保存提示保存时会更新已有密码，不会无限创建重复登录项。

## 分享链接

新安装版本默认使用 `https://share.password-entry-share.workers.dev`；本地开发时可在设置中改为 `http://127.0.0.1:8787`。

### 无需服务器域名配置部署（需要科学访问）

自行部署 Cloudflare Worker 后，在桌面端“设置 → 分享服务”中填入你自己的 Worker URL。部署说明见 [share-api/README.md](share-api/README.md)：

自行部署时，在 `share-api/` 目录运行 `npm install && npx wrangler login && npm run deploy:self`；脚本会自动创建或复用 D1、执行迁移并发布 Worker。

```bash
python3 share-api/server.py
```

桌面端会在客户端生成 AES-GCM 加密副本、查看密钥和撤销密钥；云端 D1 只保存加密副本和分享生命周期信息。部署到 HTTPS 地址后，在桌面端“设置 → 分享服务”中填写 API 地址，例如 `https://share.example.com`；远程地址必须使用 HTTPS，本地开发才允许 `http://127.0.0.1:8787`。

链接中的查看密钥位于 URL fragment（`#` 后），服务端不会收到它。包含 TOTP 时，分享页会在浏览器本地按配置周期生成实时验证码并显示剩余有效秒数；这类分享会提示接收方可持续生成验证码，并限制为最多 1 小时。当前 MVP 支持登录项、默认 7 天过期、复制链接和手动撤销，邮箱限制、附件和单次查看尚未加入。

### AI 一键部署与验收

仓库内置部署 Skill：[skills/password-entry-share-deploy](skills/password-entry-share-deploy)。在支持仓库 Skill 的 AI 环境中，可以直接提出：

```text
使用 password-entry-share-deploy 部署我的分享服务
```

AI 会检查 Wrangler 登录状态；如果尚未登录，会打开 Cloudflare 授权流程并等待你完成登录，然后执行 `npm run deploy:self`，自动创建或复用 D1、执行迁移、检查 Worker 并发布。部署完成后，把 AI 输出的 Worker URL 填入桌面端“设置 → 分享服务”。

建议按以下步骤验收：

1. 创建并复制一个分享链接，在浏览器中打开并确认登录信息可以解密显示。
2. 移除链接末尾的 `#` 密钥，确认页面显示“分享链接已失效或者过期”。
3. 在桌面端撤销分享，再次打开链接，确认页面显示相同的失效提示。
4. 确认 D1 中只保存加密密文和生命周期字段，不包含用户名或密码明文。
