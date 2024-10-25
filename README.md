## 一键脚本
```
bash <(curl -fsSL acme-red-eight.vercel.app)
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
acme.sh --issue -d example.com --keylength ec-256 --standalone
```
```
acme.sh --issue --dns dns_cf -d *.example.com --keylength ec-256
```

安装证书
```
mkdir -p /root/cert && \
acme.sh --install-cert -d example.com --ecc \
--key-file /root/cert/example.com.key \
--fullchain-file /root/cert/example.com.crt \
--reloadcmd "systemctl reload nginx"
```

项目地址：https://github.com/acmesh-official/acme.sh [How to use DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)

