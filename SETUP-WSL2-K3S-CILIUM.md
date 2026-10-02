# WSL2 + K3s + Cilium — Hướng dẫn từng bước (laptop Windows)

Mục tiêu: dựng cụm K3s 1 node trong Ubuntu WSL2, dùng Cilium thay kube-proxy
(WireGuard + L7 + Hubble) rồi chạy demo `order-service -> payment-service`
theo đúng `De-xuat-Cong-nghe-va-Kien-truc-Phong-thu-Chu-dong.md` §3.1–§3.2.

> eBPF trên kernel WSL2 bị giới hạn so với máy Ubuntu vật lý/VPS.
> Muốn lấy số liệu chuẩn cho báo cáo (MTTD, connectivity) thì chạy PoC
> trên VPS Ubuntu 4GB; môi trường WSL2 này chỉ dùng để viết và thử policy/manifest.

## 0. Yêu cầu

- Windows 11 + WSL2, distro Ubuntu (đã có: `wsl --list` thấy `Ubuntu Running`)
- Docker Desktop (không bắt buộc, không dùng cho K3s)
- RAM: cấp tối thiểu 4GB cho WSL2 (`%USERPROFILE%\.wslconfig`: `memory=4GB`)

## 1. Cài đặt (chạy 1 lệnh trong Ubuntu)

Từ PowerShell:

```powershell
wsl -d Ubuntu -e bash -lc "bash /mnt/c/Users/tdanh/Desktop/DACN/src-zerotrust/scripts/install-k3s-cilium.sh"
```

Script trên thực hiện các bước sau (`scripts/install-k3s-cilium.sh`):

1. `apt install curl iptables wireguard-tools`
2. `curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-backend=none --disable-network-policy --disable-kube-proxy --disable servicelb --disable traefik" sh -`
3. Copy kubeconfig → `~/.kube/config`
4. Cài `helm` + `cilium` CLI (v0.20.1)
5. `cilium install --set kubeProxyReplacement=true --set encryption.enabled=true --set encryption.type=wireguard --set l7Proxy=true --set hubble.enabled=true --set hubble.relay.enabled=true --set hubble.ui.enabled=true`
6. `cilium status --wait`

Kiểm tra:

```powershell
wsl -d Ubuntu -e bash -lc "export KUBECONFIG=~/.kube/config; kubectl get nodes -o wide; cilium status; kubectl -n kube-system get pods"
```

## 2. Triển khai demo và policy

```powershell
wsl -d Ubuntu -e bash -lc "export KUBECONFIG=~/.kube/config; kubectl apply -f /mnt/c/Users/tdanh/Desktop/DACN/src-zerotrust/manifests/00-namespaces.yaml; kubectl apply -f /mnt/c/Users/tdanh/Desktop/DACN/src-zerotrust/manifests/order-payment-demo.yaml; kubectl -n production get pods,svc"
```

Đi theo lộ trình staging như docs khuyến nghị: quan sát trước, enforce sau:

```powershell
wsl -d Ubuntu -e bash -lc "export KUBECONFIG=~/.kube/config; cilium connectivity test; hubble observe -n production --follow"
```

Enforce Zero Trust — làm đúng thứ tự: Cilium L7 trước, default-deny sau:

```powershell
wsl -d Ubuntu -e bash -lc "export KUBECONFIG=~/.kube/config; kubectl apply -f /mnt/c/Users/tdanh/Desktop/DACN/src-zerotrust/policies/secure-payment-service-zt.yaml; kubectl apply -f /mnt/c/Users/tdanh/Desktop/DACN/src-zerotrust/policies/allow-order-to-payment-l4.yaml; kubectl apply -f /mnt/c/Users/tdanh/Desktop/DACN/src-zerotrust/policies/default-deny.yaml"
```

## 3. Kiểm chứng

Image demo (`http-echo`) không có sẵn `curl`, nên cần tạo một Pod client
mang nhãn `app=order-service` để gửi request thử (toàn bộ lệnh dưới đây
đã chạy kiểm chứng trên cụm này):

```bash
# Pod client mang nhãn order-service
kubectl -n production run client-order --image=curlimages/curl:8.5.0 \
  --labels=app=order-service -- sleep 3600

# Chỉ POST /v1/charge từ order -> payment được phép (L7) → 200
kubectl -n production exec client-order -- \
  curl -s -m 10 -o /dev/null -w "%{http_code}\n" \
  -X POST http://payment-service:8080/v1/charge

# Sai method/path → Envoy chặn 403
kubectl -n production exec client-order -- \
  curl -s -m 10 -o /dev/null -w "%{http_code}\n" http://payment-service:8080/
kubectl -n production exec client-order -- \
  curl -s -m 10 -o /dev/null -w "%{http_code}\n" \
  -X POST http://payment-service:8080/v1/refund

# Pod không nhãn (đóng vai attacker) → timeout ở L3/L4
kubectl -n production run client-evil --image=curlimages/curl:8.5.0 -- sleep 3600
kubectl -n production exec client-evil -- \
  curl -s -m 10 -o /dev/null -w "%{http_code}\n" http://payment-service:8080/

# Bằng chứng tổng hợp cho báo cáo
cilium connectivity test
hubble observe -n production --last 20
```

Kết quả đã đo trên cụm WSL2 này:

| Trường hợp | Kết quả |
|---|---|
| `POST /v1/charge` từ order | 200 |
| `GET /` từ order | 403 (Envoy L7 chặn) |
| `POST /v1/refund` từ order | 403 (sai path) |
| Pod không nhãn | timeout (L3/L4 chặn) |
| `cilium connectivity test` | 78/79 pass |

## 4. Sự cố thường gặp

| Lỗi | Cách sửa |
|---|---|
| `k3s: Failed to ... iptables` | `sudo apt install iptables`, trên WSL2 cần `sudo update-alternatives --set iptables /usr/sbin/iptables-legacy` |
| `cilium install` pending | `kubectl -n kube-system get pods` xem Pod nào CrashLoop, thường thiếu kernel module → chuyển sang VPS |
| `hubble observe` không có flow | Hubble relay chưa ready: `kubectl -n kube-system rollout status deploy/hubble-relay` |
| `kubectl exec` vào Pod Cilium báo `pod does not exist` | API server k3s vừa restart (kiểm tra bằng events); đợi ~60s rồi thử lại, exec vào Pod thường không bị ảnh hưởng |
| WSL2 ăn RAM | `.wslconfig` giới hạn `memory=4GB`, `wsl --shutdown` rồi mở lại |

## 5. Cấu trúc thư mục

```
src-zerotrust/
  SETUP-WSL2-K3S-CILIUM.md      # file này
  scripts/install-k3s-cilium.sh # cài 1 lệnh
  manifests/00-namespaces.yaml
  manifests/order-payment-demo.yaml
  policies/default-deny.yaml              # NetworkPolicy deny-all + DNS
  policies/allow-order-to-payment-l4.yaml # CHỈ egress L4 (xem lưu ý dưới)
  policies/secure-payment-service-zt.yaml # Cilium L7: order POST /v1/charge -> payment
```

> LƯU Ý (bài học rút ra khi kiểm chứng): Cilium gộp các rule theo logic OR.
> Nếu mở ingress L4-only bằng NetworkPolicy chuẩn trên cùng port/source,
> rule L4 sẽ che rule L7 và `GET /` sẽ lọt (đo thực tế ra 200).
> Vì vậy ingress CHỈ mở trong CiliumNetworkPolicy (L4+L7);
> NetworkPolicy chuẩn chỉ mở egress. Test duy nhất bị fail trong
> `cilium connectivity test` là `check-log-errors`, nguyên nhân là Pod
> restart lúc boot WSL2 + kernel WSL2 thiếu `CONFIG_INET_DIAG_DESTROY`
> (vô hại với PoC).
