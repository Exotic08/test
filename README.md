# NoRiptideCooldown

Plugin Paper/Spigot nhỏ để **giảm hoặc xóa thời gian hồi chiêu của đinh ba sau khi bay bằng Riptide**.

> Plugin này chỉnh phần **hồi chiêu/khóa dùng lại sau khi Riptide đã kích hoạt**. Nó **không** chỉnh thời gian giữ chuột phải/charge để kích hoạt Riptide.

## Tính năng

- Mặc định đặt item cooldown Riptide về `0` tick.
- Mặc định cũng cố gắng xóa trạng thái `riptiding/auto-spin` ngắn sau khi bay, vì trên một số version đây chính là phần làm bạn không dùng lại ngay được.
- Có thể chỉnh cooldown thành số tick bất kỳ trong `config.yml`.
- Tự ghi đè nhiều lần sau event để thắng vanilla/plugin khác set cooldown muộn.
- Có fallback cho server cũ và thử dùng ItemStack cooldown API trên server mới.

## Cài đặt nhanh

1. Build plugin:

   ```bash
   mvn package
   ```

2. Copy file jar:

   ```text
   target/NoRiptideCooldown-1.0.0.jar
   ```

   vào thư mục:

   ```text
   plugins/
   ```

3. Restart server Paper.

## Config quan trọng

File `plugins/NoRiptideCooldown/config.yml`:

```yml
# 0 = không hồi chiêu item
# 20 ticks = 1 giây
cooldown-ticks: 0

# Ghi đè item cooldown sau khi dùng Riptide
apply-delays-ticks:
  - 0
  - 1
  - 2
  - 5

# 0 = xóa khóa dùng lại do trạng thái riptiding/auto-spin
# -1 = tắt, giữ animation/damage xoay vanilla
riptide-spin-duration-ticks: 0

# Nên để 1,2 tick để tránh bị vanilla ghi đè
riptide-spin-apply-delays-ticks:
  - 1
  - 2
```

Nếu bạn chỉ muốn xóa **item cooldown** và muốn giữ nguyên trạng thái xoay/damage vanilla, đổi:

```yml
riptide-spin-duration-ticks: -1
```

Ví dụ muốn hồi chiêu 0.25 giây:

```yml
cooldown-ticks: 5
riptide-spin-duration-ticks: 5
```

Sau khi sửa config, dùng:

```text
/nrc reload
```

hoặc restart server.

## Lệnh

- `/nrc status` - xem trạng thái.
- `/nrc reload` - reload config.
- `/nrc set <ticks>` - đổi nhanh `cooldown-ticks`, ví dụ `/nrc set 0`.

Permission: `noriptidecooldown.admin` mặc định cho OP.

## Vì sao không làm datapack?

Datapack vanilla không có hook sạch để xóa/chỉnh cooldown nội bộ và trạng thái riptiding sau khi dùng Riptide. Với Paper server, plugin là cách ổn định nhất để chỉnh đúng phần **hồi chiêu/khóa dùng lại** mà không đụng tới thời gian charge/kích hoạt chiêu.
