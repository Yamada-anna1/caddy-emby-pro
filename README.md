# Caddy + Emby 多站点及推流管理脚本

![Language](https://img.shields.io/badge/Language-Bash-green.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-V6%20Pro-orange.svg)

交互式 Caddy 管理脚本，支持普通 Emby 反向代理，以及“登录/API 上游 + 实际视频流上游”的前后端分流。脚本会接管上游返回的 `302 Location`，将最终视频请求重新导向 VPS 上的 Caddy。配置不依赖特定客户端的专有能力，适用于支持自定义 Emby 服务器地址的客户端和播放器。

> 本项目不提供 Emby 账号、节点或绕过授权功能。请仅代理你有权访问的服务，并遵守上游服务、Cloudflare 和 VPS 服务商的使用条款。

## 功能

- 自动安装并管理 Caddy
- 普通反代，多站点追加或同域名覆盖
- 前后端反代推流，多站点独立 snippet
- 默认接入仅需填写入口域名和 443，客户端/播放器路径留空；兼容路径与兼容线路域名仍可继续使用
- 支持 1–8 个固定流节点，每个节点生成独立内部路径和 `Location` 正则
- 入口域名与兼容线路域名都会在本域内接管视频流，避免跨域丢失鉴权信息
- 内部推流前缀，不依赖上游路径必须是 `/stream/*`
- 流节点再次返回 302 时继续改写，防止客户端绕过 VPS
- Caddyfile 备份校验、格式化、验证、原子替换和失败回滚
- 通过 Caddy adapter 展开 `import` 后，递归检查多域名、协议、端口、大小写、通配符及嵌套 `handle` 冲突
- 校验正式配置写入结果、Caddy 重启状态和回滚后的服务状态
- 回滚前再次校验当前文件，避免覆盖其他进程刚写入的新配置
- 删除普通站点或完整推流站点组
- 快捷命令 `c` 再次打开脚本

## 一键安装

使用 root 用户运行：

```bash
bash <(curl -fsSL --retry 3 https://raw.githubusercontent.com/Yamada-anna1/caddy-emby-pro/main/install_caddy_emby.sh)
```

更稳妥的方式是先下载并检查：

```bash
curl -fL --retry 3 \
  -o install_caddy_emby.sh \
  https://raw.githubusercontent.com/Yamada-anna1/caddy-emby-pro/main/install_caddy_emby.sh

less install_caddy_emby.sh
sudo bash ./install_caddy_emby.sh
```

## 主菜单

```text
1.  安装环境 & Caddy
2.  添加/覆盖 普通反代配置（支持多站）
3.  添加/覆盖 前后端反代推流配置（支持多站）
4.  删除指定站点配置
5.  查看 Caddy 配置文件
6.  停止 Caddy
7.  重启 Caddy
8.  查询 443/80 端口占用
9.  强制处理端口占用（修复启动失败）
10. 卸载 Caddy
0.  退出脚本
```

## 菜单 3：前后端反代推流

脚本会按以下顺序询问：

| 顺序 | 参数 | 示例 | 说明 |
|---|---|---|---|
| 1 | 客户端入口域名 | `dao.example.com` | 客户端或播放器实际连接的域名，不带协议和路径 |
| 2 | 兼容线路域名（必填） | `db.example.com` | 提供兼容路径 `/db.example.com` 和备用直连；客户端/播放器默认将路径留空 |
| 3 | 登录/API 上游 URL | `https://api.example.com:443` | 登录、媒体库、图片和播放接口入口 |
| 4 | 实际 302 推流上游 URL | `https://stream-a.example.com:443,https://stream-b.example.com:443` | 支持 1–8 个节点，以逗号分隔；顺序填写所有实际 `Location` 主机 |
| 5 | 内部推流前缀 | `__dao_stream` | 自动生成，可修改；不是客户端需要填写的路径 |
| 6 | 摘要确认 | `y/N` | 确认前不会修改 Caddyfile |

客户端/播放器填写示例：

```text
地址：https://dao.example.com
端口：443
路径：留空（不要填写 `/`）
```

已有客户端无需迁移，仍可继续使用：

```text
兼容路径：/db.example.com
备用直连：https://db.example.com
```

### 工作流程

```text
Emby 客户端/播放器
  │
  ├─ https://dao.example.com/emby/...
  │          ↓
  │       Caddy → 登录/API 上游
  │
  ├─ 旧客户端仍可使用：
  │    https://dao.example.com/db.example.com/emby/...
  │    https://db.example.com/emby/...
  │          ↓
  │       Caddy → 同一个登录/API 上游
  │
  └─ API 返回 302：
       https://流节点A/任意路径?签名
       https://流节点B/任意路径?签名
                    ↓ Caddy 分别改写
       https://当前请求域名/__dao_stream/...        → 流节点A
       https://当前请求域名/__dao_stream_节点B_.../ → 流节点B
```

入口域名的根路径会直接进入 API 上游。兼容路径的 `handle_path` 只删除线路前缀，各流节点的 `handle_path` 只删除自己的内部前缀；剩余原始路径、Range 请求、查询参数和签名都会继续转发。第一个流节点继续使用基础内部前缀，便于兼容短期缓存的旧播放地址。

## DNS 要求

菜单 3 继续保留兼容线路域名。为保证默认入口、兼容线路域名的备用直连及其证书均可用，两条 DNS 记录都必须指向 VPS：

```text
dao.example.com  A/AAAA  → VPS
db.example.com   A/AAAA  → VPS
```

- 首次测试建议使用 DNS Only。
- 使用 Cloudflare 代理时，SSL/TLS 模式应为 `Full (strict)`，不要使用 `Flexible`。
- VPS 需要开放 TCP 80 和 443。
- 没有正确配置 IPv6 时应删除错误的 AAAA 记录。

## 如何确认真实 302 流节点

服主提供的线路名不一定等于当前真实流节点。应以播放请求返回的 `Location` 为准。

为避免播放签名进入 Shell 历史，可使用：

```bash
read -rsp '粘贴完整播放 URL（不回显）: ' U; echo

curl -sk --range 0-0 --max-redirs 0 -D - -o /dev/null "$U" |
awk 'BEGIN{IGNORECASE=1}
     /^HTTP\// {gsub("\r",""); print}
     /^Location:/ {
       gsub("\r","");
       sub(/\?.*/, "?<redacted>");
       print
     }'

unset U
```

需要核对域名、节点编号和端口。若同一站点会在 `s01`、`s02` 等节点间切换，应把所有实际节点一次填入菜单 3；再次输入相同客户端入口域名会原位更新该站点组。

### 播放出现 403

如果登录和媒体库正常、播放却显示 `Source error 403`，最常见原因是 API 下发了新流节点，而旧配置只接管原节点。未被接管的地址会让客户端绕过 VPS；若签名绑定 VPS 出口 IP，源站就会拒绝客户端直连。

处理方式：从一次真实播放请求确认 `302 Location` 的主机，把所有可能节点用逗号填入菜单 3。脚本会为每个节点生成独立固定上游，不会创建任意主机动态代理。

## 多站点、覆盖和删除

- 每个推流站点都有稳定的唯一 snippet 名称和独立内部前缀。
- 新增推流线路时，客户端/播放器路径默认留空；现有以 `/兼容线路域名` 形式配置的兼容路径无需修改，仍然有效。
- 相同客户端入口域名再次添加时，只替换该站点整组配置。
- 其他普通站点和推流站点会保留。
- 如果新域名已经被未托管配置占用，脚本会拒绝修改，避免误删手写配置。检测范围包括多域名站点、带协议或端口的站点地址、大小写差异、通配符以及 `import` 引入的配置。
- 菜单 4 删除推流站点时，会同时删除 API snippet、流 snippet、兼容线路域名块和客户端入口域名块。
- Caddyfile 修改前最多保留 5 份经过内容校验的唯一备份，位置为 `/var/backups/caddy-emby-pro/`。

写入时先生成与 Caddyfile 位于同一目录的候选文件。候选配置通过 `caddy fmt`、`caddy validate` 和 adapter 解析后才会备份并原子替换正式文件；备份失败、并发修改、权限复制失败、写入校验失败、服务处于过渡/未知状态或 Caddy 重启失败都会停止操作。重启失败时，脚本会先确认磁盘上的文件仍是本次候选版本，再分别验证磁盘配置和服务状态是否恢复成功；若发现其他进程已写入新内容，会保留该内容和旧备份，拒绝用旧配置覆盖。

`Location` 改写正则使用 Caddy/Go 兼容的捕获组，并要求流节点主机名后紧跟端口或 `/` 路径边界，避免相似域名被误改写。备份轮转无论系统时间是否回拨，都会保留本次事务刚创建的备份。

删除最后一个 HTTP 站点时，脚本只会在适配后的配置不再包含任何 Caddy app 时停止服务；如果同一配置仍承载其他 app，会继续保持 Caddy 运行。

## 验证是否经过 VPS

正确播放时应看到：

- 播放接口返回的 302 已指向客户端入口域名和内部前缀。
- 后续视频请求 Host 是客户端入口域名。
- Range 请求返回 HTTP 206，Caddy 传输字节数明显增长。
- VPS 同时出现明显的入站和出站流量。

供应商流量图通常按数分钟聚合并存在延迟，不应只根据瞬时图表判断。

## 安全提示

- 不要在 Issue 中提交 Emby Token、API Key、完整播放 URL 或原始访问日志。
- 播放路径本身可能带临时签名，排障时应删除查询参数。
- 脚本默认不启用 Caddy access log，避免长期保存鉴权信息。
- 菜单 9 和菜单 10 属于破坏性操作，执行前会要求确认。

## 致谢与来源

- 本项目基于 [AiLi1337/caddy_emby](https://github.com/AiLi1337/caddy_emby) 扩展，保留原作者署名。
- Caddy 配置行为参考 [Caddy 官方文档](https://caddyserver.com/docs/)。
- 本项目与 Caddy、Emby 及任何第三方客户端/播放器的官方项目均无隶属或授权关系。

## License

[MIT](LICENSE)
