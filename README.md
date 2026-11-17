# local_app_extension_bridge_host

桌面 App 与浏览器扩展之间的公共 Dart 宿主。和 TypeScript 客户端 `local-app-extension-bridge-client` 成对使用。

## 职责

- 在 `127.0.0.1:13555–13666` 打开 WebSocket 控制面与 `/server-info` 发现
- HMAC 配对、鉴权、心跳
- Native Messaging **只用于发现**：把监听端口交给扩展，数据面仍走 WebSocket
- 产品 RPC 由 App 通过 `registerHandler` 挂上，不进本包

## 使用

Transli 挂 `image_ocr`。VGet 挂 `download_handoff_query` 和拦截规则推送。不要把 Native Messaging 当成大数据或订阅通道。
