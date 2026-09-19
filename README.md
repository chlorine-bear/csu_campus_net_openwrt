# OpenWrt自动登录中南大学校园网脚本

由Agent编写，本人初步验证。欢迎测试，如有bug，请提交issue。

## 功能
每分钟检测校园网是否下线，如果下线，自动重新连接。路由器开机15秒后自动检测一次。

## 安装
- 下载`campus-net.conf`至`/etc/campus-net.conf`
- 修改`campus-net.conf`中的学号、密码、运营商，以及`WAN`对应的网络适配器名称，**配置权限**为`600`，防止密码意外泄漏
- 下载`campus-net-login.sh`至`/usr/bin/campus-net-login.sh`
- 创建**计划任务**：在OpenWrt后台打开系统-计划任务，在`crontab`中添加行
  ```
  */1 * * * * /usr/bin/campus-net-login.sh -q >/dev/null 2>&1
  ```
  保存并应用
- 创建**开机启动项**：在OpenWrt后台打开系统-启动项-本地启动脚本，在`exit 0`前添加行
  ```
  (sleep 15 && /usr/bin/campus-net-login.sh -q) &
  ```
  保存并应用

## 日志查看
日志保存在`/var/log/campus-net.log`中
