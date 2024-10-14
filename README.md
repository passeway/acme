## 一键脚本
```
bash <(curl -fsSL https://raw.githubusercontent.com/passeway/acme/refs/heads/main/acme.sh)
```
安装nginx
```
apt install nginx
```
安装acme
```
curl https://get.acme.sh | sh
```
添加软链接
```
ln -s  /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
```
切换CA机构： 
```
acme.sh --set-default-ca --server letsencrypt
```
申请证书
```
acme.sh --issue -d example.com -k ec-256 --standalone
```
安装证书
```
mkdir -p /root/cert \
acme.sh --install-cert -d example.com --ecc \
--key-file /root/cert/example.com.key \
--fullchain-file /root/cert/example.com.crt \
--reloadcmd "systemctl reload nginx"
```
