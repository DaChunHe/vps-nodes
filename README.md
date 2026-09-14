# vps-nodes

Ubuntu/Debian VPS 双节点安装脚本，部署 Hysteria 2、Xray VLESS-REALITY、WARP 分流和订阅服务。

## 一键部署

在目标 VPS 上以 root 执行：

```bash
curl -fsSL https://github.com/DaChunHe/vps-nodes/raw/refs/heads/main/install.sh -o /tmp/vps-nodes-install.sh
chmod 700 /tmp/vps-nodes-install.sh
/tmp/vps-nodes-install.sh
```

也可以先下载后检查脚本，再执行。脚本会自动安装依赖、配置服务并输出新订阅地址。

## 设计原则

本项目已经按更稳妥的工业级模板收敛，核心原则如下：

- REALITY 不做“一刀切硬编码分流”；测速流量默认直连，只有 AI 相关域名才在 WARP 可用时进入 `warp-out`。
- WARP 未就绪时不强行把 `google.com` 等基础域名引流到本地 SOCKS5，而是保留 `direct` 兜底，避免出现测速误报 `-1` 或链接失败。
- Hysteria 2 不使用动态 `type: proxy` 反代；改为本地静态 `type: file` 伪装，避免上游 TLS 安全策略变更导致服务 CrashLoop。
- 监听统一绑定 `0.0.0.0`，避免只监听本地回环导致公网访问问题。
- 配置文件和证书在部署前会做基本合法性检查，避免 `xray run -test` 或 `hysteria-server` 启动失败时无有效报错。

## 使用前注意

- 仅支持 Ubuntu/Debian、amd64/arm64，必须以 root 运行。
- 脚本不会清空现有 iptables 规则；云厂商安全组仍需放行 TCP `443`、UDP `24443` 和 TCP `27695`。
- 脚本会为这三个端口补充最小化的本机 ACCEPT 规则，但 Oracle Cloud 的 Security List/NSG 仍必须单独放行。
- Oracle Cloud 控制台进入 `VCN -> Subnet -> Security List`（如果实例绑定了 NSG，还要进入对应 NSG），添加入站规则：来源 `0.0.0.0/0`，TCP 目标端口 `443`；来源 `0.0.0.0/0`，UDP 目标端口 `24443`；来源 `0.0.0.0/0`，TCP 目标端口 `27695`。修改后等待约几十秒再测试。
- 每次部署都会生成新的订阅地址，例如 `http://服务器IP:27695/sub-20260914183000-a1b2c3d4.txt`，并同步更新兼容地址 `/sub.txt`；旧订阅文件会被清理。订阅内容包含节点密码和 UUID，服务端也会发送禁止缓存的响应头。更新后优先使用脚本最后输出的新地址。
- 订阅内容按 v2rayN 常用格式进行 Base64 编码；如果客户端仍提示无效，可将脚本最后输出的单条节点链接手动导入。
- WARP 是可选出口：安装或连接失败时，AI 域名会自动回退到直连，避免整个 Reality 节点因 `127.0.0.1:40000` 不通而不可用；WARP 恢复后重新运行脚本即可重新生成并启用分流配置。
- REALITY 使用 `learn.microsoft.com:443` 作为成熟稳定的伪装目标，并只对 AI 相关域名进行 WARP 分流；基础测速和普通网页内容默认走 `direct`。
- Hysteria 2 使用本地静态文件伪装，避免依赖外部代理 URL，提升稳定性；本地目录为 `/var/www/hy2_fake`。
- WARP、Xray、Hysteria 任一关键服务启动失败时脚本会退出，不会继续打印安装成功信息。

## 典型部署后检查

```bash
systemctl status xray hysteria-server nodes-sub --no-pager
ss -lntup | grep -E ':(443|24443|27695)\b'
curl -I http://127.0.0.1:27695/sub.txt
```

如果上述检查都正常，再删除客户端里旧节点并重新导入最新订阅，避免旧 IP 和旧配置继续干扰。