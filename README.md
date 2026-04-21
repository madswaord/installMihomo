# installMihomo

`mihomo` 一键安装、升级、卸载脚本。

许可证：`GPL-3.0-only`

脚本文件：

```bash
mihomo_auto_update.sh
```

## 适用环境

- Linux
- `systemd`
- `root` 用户执行
- 网络可访问 GitHub Releases

## 功能

- 自动检测当前系统版本
- 自动检测是否已安装 `mihomo`
- 已安装时显示当前版本、二进制路径、配置目录
- 安装 `mihomo`
- 升级 `mihomo`
- 卸载 `mihomo`
- 自动选择最合适的官方发布包
- 安装和升级过程按步骤显示

## 快速开始

直接拉取并运行：

```bash
git clone git@github.com:madswaord/installMihomo.git
cd installMihomo
chmod +x mihomo_auto_update.sh
sudo bash mihomo_auto_update.sh
```

## 默认安装位置

- 二进制：`/usr/local/bin/mihomo`
- 配置目录：`/etc/mihomo`
- 配置文件：`/etc/mihomo/config.yaml`
- systemd 服务文件：`/etc/systemd/system/mihomo.service`

## 使用方法

给执行权限：

```bash
chmod +x mihomo_auto_update.sh
```

交互式运行：

```bash
sudo bash mihomo_auto_update.sh
```

也可以直接指定动作：

```bash
sudo bash mihomo_auto_update.sh install
sudo bash mihomo_auto_update.sh upgrade
sudo bash mihomo_auto_update.sh uninstall
```

## 菜单首页显示

进入脚本后会先自动显示：

- 当前系统版本
- `mihomo` 是否已安装
- 当前 `mihomo` 版本
- 当前二进制路径
- 当前配置目录

## 安装说明

执行安装后，脚本会先提示你把配置文件放到：

```bash
/etc/mihomo/config.yaml
```

放好 `config.yaml` 之后，按回车继续。

安装流程会自动执行：

1. 检测系统和当前安装状态
2. 下载官方最新适配版本
3. 安装二进制
4. 写入 `systemd` 服务
5. 启动 `mihomo`
6. 检查 `status`
7. 成功后设置开机自启

## 升级说明

升级时会自动：

- 检测当前安装路径
- 备份旧版本二进制
- 下载最新适配版本
- 停止服务并替换二进制
- 启动服务
- 启动失败时自动回滚

## 卸载说明

卸载时会：

- 停止并禁用 `mihomo`
- 删除服务文件
- 删除二进制
- 询问是否删除配置目录

## 仓库结构

```bash
.
├── mihomo_auto_update.sh
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── .gitignore
```

## 验证命令

脚本语法检查：

```bash
bash -n mihomo_auto_update.sh
```

查看服务状态：

```bash
systemctl status mihomo --no-pager
```

查看日志：

```bash
journalctl -u mihomo -o cat -e
```

## 参考

- mihomo systemd 官方文档：<https://wiki.metacubex.one/startup/service/>
- mihomo Releases：<https://github.com/MetaCubeX/mihomo/releases>
