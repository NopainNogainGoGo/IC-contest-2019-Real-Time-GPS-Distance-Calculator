# Verilog / Fixed-Point Design Notes

## 1. Signed / Unsigned
### 混用 Signed 與 Unsigned
只要**任何一個運算元是 unsigned**，Verilog 會將**整個運算式**變為 unsigned，再進行計算。
這會導致負數被解讀成非常大的正數。

### 錯誤範例

```verilog
wire signed [24:0] delta_lon;
delta_lon = B_LON - A_LON;   // B_LON、A_LON 為 unsigned
```

### 正確寫法

```verilog
wire signed [24:0] delta_lon;
assign delta_lon = $signed({1'b0, B_LON}) -$signed({1'b0, A_LON});
```

### 原則

- 只要混用 signed / unsigned，就要特別小心。
- 使用 `$signed()` 強制轉換。
- 等號左右兩側最好保持相同的 signed

---

# 2. 加法 / 減法
## N bit + N bit
兩個 N-bit 數字相加，結果需要 **N+1 bit** 才能保證不溢位。

```
N bit + N bit
↓

N+1 bit
```

### 錯誤

```verilog
wire [7:0] sum;
assign sum = a + b;
```

若 255 + 255 = 510
8 bit 只能留下 254 ，高位直接消失。

---

### 正確

```verilog
wire [8:0] sum;
assign sum = {1'b0, a} + {1'b0, b};
```

---

## 減法

硬體沒有真正的減法器。

```
A - B

↓

A + (~B + 1)
```

也就是

**加上二補數**。

因此減法也需要考慮溢位。


# 3. 乘法

## Bit Width

N bit × M bit

結果需要

```
N + M bit
```


若只宣告 16 bit：

```verilog
wire [15:0] result;

assign result = a * b;
```

高位會直接被截掉（Truncated）。

---

## 乘法後的 Q-format

固定小數點乘法後，小數位數也會相加。

例如

```
Q8.16 × Q8.16

↓

Q16.32
```

若希望結果仍為

```
Q8.16
```

需要右移：

```verilog
result = product >>> 16;
```

或直接取位元：

```verilog
result = product[47:16];
```

---

## 常數乘法

避免直接使用乘法器。

例如：

```
a × 3
```

建議改成：

```verilog
(a << 1) + a
```
可節省硬體資源。

---

# 4. 除法

除法器通常：

- Area 大
- Latency 高
- Timing 差

很多情況可以改成：

```
x / 5

↓

x × 0.2
```

也就是

**乘上倒數**。

固定小數點中十分常見。

---

# 5. Fixed-Point 四捨五入

直接右移：

```verilog
result = value >>> n;
```

屬於

**Truncate**

永遠往零方向截斷。
會造成 Bias。

建議四捨五入(Rounding)：

```verilog
result = (value + (1 << (n-1))) >>> n;
```

先加上半個 LSB 再右移。



---

# 6. Multiply First, Divide Last

原因：
乘法可以保留更多有效位元。
若太早除法：

```
100 / 3

↓

33
```

後續再乘

```
33 × 7
```

誤差已經存在。

若改成

```
100 × 7

↓

700 / 3

↓

233
```

精度通常較佳。

---

# 7. ROM Lookup

## Sequential Search

每筆依序比較：

```
0
1
2
3
...
127
```

ROM 共 128 筆。

最差：

```
128 次
```

時間複雜度：

```
O(N)
```

---

## Binary Search

ROM 已排序。

每次砍掉一半。

```
128

↓

64

↓

32

↓

16

↓

8

↓

4

↓

2

↓

1
```

最多：

```
log₂(128) = 7
```

時間複雜度：

```
O(log N)
```

---

## 利用等距特性

若 ROM 幾乎等距：

```
x = xmin + addr × Δ
```

可直接估計：

```
addr ≈ (x - xmin) / Δ
```

可大幅減少搜尋次數。

缺點：

需要除法器。

若 Δ 為固定值，可改成：

```
addr ≈ (x - xmin) × (1 / Δ)
```

利用固定小數點乘法取代除法。
