# K3s + Cilium Zero Trust — Example Repo

Ví dụ chạy được (reproducible example) cho cụm PoC **K3s 1 node + Cilium**
(WireGuard, L7, Hubble): default-deny toàn cụm, chỉ cho
`order-service → payment-service` đúng `POST /v1/charge`.

## Bắt đầu nhanh

Đọc **[SETUP-WSL2-K3S-CILIUM.md](SETUP-WSL2-K3S-CILIUM.md)** — hướng dẫn từng bước
trên laptop Windows (Ubuntu WSL2): cài K3s, cài Cilium, deploy demo,
enforce policy, kiểm chứng.

```powershell
# Cài 1 lệnh trong Ubuntu WSL2
wsl -d Ubuntu -e bash -lc "bash scripts/install-k3s-cilium.sh"
```

## Cấu trúc

```
scripts/install-k3s-cilium.sh   # cài K3s (nhường mạng cho Cilium) + Cilium + Hubble
manifests/                      # namespaces + demo order/payment
policies/
  default-deny.yaml             # NetworkPolicy deny-all + DNS
  allow-order-to-payment-l4.yaml# CHỈ egress L4 (ingress do Cilium L7 nắm)
  secure-payment-service-zt.yaml# Cilium L7: order POST /v1/charge -> payment
```

## Kết quả đã kiểm chứng

| Trường hợp | Kết quả |
|---|---|
| `POST /v1/charge` từ order | 200 |
| `GET /` từ order | 403 (Envoy L7 chặn) |
| `POST /v1/refund` từ order | 403 (sai path) |
| Pod không nhãn | timeout (L3/L4 chặn) |
| `cilium connectivity test` | 78/79 pass |

## Yêu cầu

- Windows 11 + WSL2 + Ubuntu (dev) hoặc Ubuntu VPS 4GB (lấy số liệu chuẩn)
- Chi tiết trong [SETUP-WSL2-K3S-CILIUM.md](SETUP-WSL2-K3S-CILIUM.md)
