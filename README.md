# Caddy + Emby 多站点及推流管理脚本

![Language](https://img.shields.io/badge/Language-Bash-green.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-V6%20Pro-orange.svg)

交互式 Caddy 管理脚本，支持普通 Emby 反向代理，以及“登录/API 上游 + 实际视频流上游”的前后端分流。脚本会接管上游返回的 `302 Location`，将最终视频请求重新导向 VPS 上的 Caddy。

> 本项目不提供 Emby 账号、节点或绕过授权功能。请仅代理你有权访问的服务，并遵守上游服务、Cloudflare 和 VPS 服务商的使用条款。

## 功能

- 自动安装并管理 Caddy
- 普通反代，多站点追加或同域名覆盖
- 前后端反代推流，多站点独立 snippet
- 自动解析实际流节点并生成 `Location` 正则
- 内部推流前缀，不依赖上游路径必须是 `/stream/*`
- 流节点再次返回 302 时继续改写，防止客户端绕过 VPS
- Caddyfile 备份、格式化、验证、原子替换和失败回滚
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
| 1 | 客户端入口域名 | `dao.example.com` | Hills 实际连接的域名，不带协议和路径 |
| 2 | 线路域名 / Hills 路径 | `db.example.com` | Hills 路径为 `/db.example.com` |
| 3 | 登录/API 上游 URL | `https://api.example.com:443` | 登录、媒体库、图片和播放接口入口 |
| 4 | 实际 302 推流上游 URL | `https://stream.example.com:443` | 必须以真实播放请求的 `Location` 为准 |
| 5 | 内部推流前缀 | `__dao_stream` | 自动生成，可修改；不是 Hills 路径 |
| 6 | 摘要确认 | `y/N` | 确认前不会修改 Caddyfile |

对应的 Hills 配置：

```text
地址：https://dao.example.com
端口：443
路径：/db.example.com
```

### 工作流程

```text
Hills
  │
  ├─ https://dao.example.com/db.example.com/...
  │          ↓
  │       Caddy → 登录/API 上游
  │
  └─ API 返回 302：
       https://真实流节点/任意路径?签名
                    ↓ Caddy 改写
       https://dao.example.com/__dao_stream/任意路径?签名
                    ↓
       Caddy → 真实流节点
```

`handle_path` 只删除脚本添加的内部前缀，原始路径、Range 请求、查询参数和签名会原样发送到实际流节点。

## DNS 要求

菜单 3 至少需要两条 DNS 记录都指向 VPS：

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

需要核对域名、节点编号、端口以及是否从 `s01` 切换到了 `s02`。如果实际节点发生变化，再次运行菜单 3，输入相同客户端入口域名即可原位更新该站点组。

## 多站点、覆盖和删除

- 每个推流站点都有稳定的唯一 snippet 名称和独立内部前缀。
- 相同客户端入口域名再次添加时，只替换该站点整组配置。
- 其他普通站点和推流站点会保留。
- 如果新域名已经被未托管配置占用，脚本会拒绝修改，避免误删手写配置。
- 菜单 4 删除推流站点时，会同时删除 API snippet、流 snippet、线路域名块和客户端入口域名块。
- Caddyfile 修改前最多保留 5 份备份，位置为 `/var/backups/caddy-emby-pro/`。

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
- 本项目与 Caddy、Emby、Hills 官方无隶属或授权关系。

## License

[MIT](LICENSE)
