# vps-nodes

Ubuntu/Debian VPS 双节点安装脚本，部署 Hysteria 2、Xray VLESS-REALITY、WARP 分流和订阅服务。

## 一键部署

将仓库提交并推送到 GitHub 后，在目标 VPS 上以 root 执行：

```bash
curl -fsSL https://github.com/DaChunHe/vps-nodes/raw/refs/heads/main/install.sh -o /tmp/vps-nodes-install.sh
chmod 700 /tmp/vps-nodes-install.sh
/tmp/vps-nodes-install.sh
```

也可以先下载后检查脚本，再执行。脚本会自动安装依赖、配置服务并输出订阅地址。

## 使用前注意

- 仅支持 Ubuntu/Debian、amd64/arm64，必须以 root 运行。
- 脚本不会清空现有 iptables 规则；云厂商安全组仍需放行 TCP `443`、UDP `24443` 和 TCP `27695`。
- 订阅地址包含节点密码和 UUID。脚本使用随机文件名，但订阅服务仍通过 HTTP 提供，不适合在不可信网络中直接传输；生产环境应放在 HTTPS 反向代理后，或限制 `27695` 的来源 IP。
- 订阅内容按 v2rayN 常用格式进行 Base64 编码；如果客户端仍提示无效，可将脚本最后输出的单条节点链接手动导入。
- WARP、Xray、Hysteria 任一关键服务启动失败时脚本会退出，不会继续打印安装成功信息。
