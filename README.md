### 一键安装脚本生成Cloudflare argo节点 

> 2026-04 重写：修复历史命令注入 / 架构识别错误 / `$argo` 未赋值 / tunnel UUID 解析错误等问题；新增 systemd 单元、端口占用探测、依赖自动安装、版本固定、ARM v6/v7 支持。详见 `argotunnel.sh` 顶部注释。

#### 一键脚本
```
curl -L https://raw.githubusercontent.com/gydchenxiao/Cloudflare-argo-tunnel-script/main/argotunnel.sh -o argotunnel.sh && bash argotunnel.sh
```

> ⚠️ 出于安全考虑，建议先 `cat argotunnel.sh` 审阅再执行，而不是 `curl | bash`。

可选环境变量（用于固定上游版本，避免 `latest` 漂移）：

```
sudo XRAY_VERSION=v1.8.23 CF_VERSION=2024.10.0 bash argotunnel.sh
```

支持的发行版：Debian 11+ / Ubuntu 20.04+ / RHEL · Rocky · Alma 9+ / Fedora 38+ / Arch。需要 systemd —— Alpine / OpenWrt 暂不支持，会直接报错退出。

#### 复制脚本到海外的nat或者vps里并回车enter  
[ssh工具推荐](https://tabby.sh/)

![](https://s2.loli.net/2024/08/30/DdVwnF73YlCWh81.png)
<br />

#### 选1进入一键安装模式，需要有在Cloudflare上托管域名，按照提示创建二级域名，绑定token,生成argo隧道节点
![](https://s2.loli.net/2024/09/09/42uxiSRmBfMUDOT.jpg)
<br />

#### 生成链接复制到浏览器打开
<br />

![](https://s2.loli.net/2024/08/30/PKMCzLBFiblptQ6.png)

#### 绑定域名
<br />

![](https://s2.loli.net/2024/08/30/eG6EF2KS8OzMBCa.png)
![](https://s2.loli.net/2024/08/30/yNkAtCbrTUDzdPZ.png)

<br />

#### 自定义一个完整的二级域名输入并回车生成代理节点
<br />

![](https://s2.loli.net/2024/09/09/BEUeYfnLSONpvAw.jpg)
<br />

#### 进入管理菜单
安装完成后，运行 `argotunnel`（或别名 `cf`）即可进入交互式管理菜单：

```
1) 列出 / 删除 tunnel
2) 启动服务
3) 停止服务
4) 重启服务
5) 卸载（保留 ~/.cloudflared 凭据）
6) 彻底卸载（含凭据）
7) 查看 v2ray 链接
8) 升级二进制 (xray + cloudflared)
9) 查看最近日志
0) 退出
```

![](https://s2.loli.net/2024/09/09/P4aYfJomvuIVRhe.jpg)

#### 卸载
- 在管理菜单里选 5 / 6；或直接 `bash argotunnel.sh` 后选 2。
- 彻底卸载后请前往 [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) 删除遗留 token。

