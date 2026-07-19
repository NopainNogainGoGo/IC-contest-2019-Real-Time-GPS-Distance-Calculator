

/*
Fixed Point Definition:
LAT/LON      Q8.16
RAD          Q0.16
LAT_RAD      Q8.32
SIN2         Q16.64
COS          Q16.32
COS_INTERP   Q32.64
A            Q0.64
ASIN         Q0.64
D            Q8.32

---
Multiply First, Divide Last
乘法可以保留更多有效位元
除法會造成 truncation 或捨去，若太早進行會失去精度

---
How to find addr?
Sequential Search 
因為 ROM 只有 128 筆最壞找 128 次

Binary Search 
因為 ROM 已排序好大約log2(128)=7次就找到。

利用等距特性: 每筆幾乎固定增加 Δ
x = xmin ​+ addr × Δ
所以 addr ≈ (x - xmin) / Δ
但除法器太大

---

定點數（Fixed-point）與 Q Format 是數位訊號處理（DSP）與硬體設計（FPGA/ASIC）中極度核心的基礎知識。在硬體世界裡，為了節省邏輯閘資源與降低延遲，我們通常不會使用浮點數（Floating-point，如 IEEE 754），而是利用 Q Format 來「模擬」小數運算。

以下為您完整拆解 Q Format 的數學概念，以及在撰寫 Verilog 時必須牢記的避坑鐵則。

---

### 一、 什麼是 Q Format？

Q Format 是一種用來表示有號定點數的記號法。硬體（暫存器或線路）本質上只能儲存 0 和 1 的整數，**小數點在哪裡，完全是由設計者「腦補」定義出來的**。

最常見的標示法為 **$Qm.n$**（或記為 $Qm.f$）：

* **$m$**：代表整數位元的數量（通常**包含 1 個 Sign bit** 符號位）。
* **$n$**：代表小數位元的數量。
* **總位元數**：$N = m + n$。

> **舉例說明：**
> 一個宣告為 `reg [15:0] val;` 的 16-bit 暫存器，如果我們定義它為 **Q4.12**：
> * 最高位 `val[15]` 是符號位 (Sign bit)。
> * `val[14:12]` 是整數位 (共 3 bits)。
> * `val[11:0]` 是小數位 (共 12 bits)。
> 
> 

### 二、 數值範圍與精度 (Range & Resolution)

針對一個 $Qm.n$ 的定點數：

* **解析度 (Resolution / LSB)**：硬體能表示的最小刻度為 $2^{-n}$。
* **最大正數**：$2^{m-1} - 2^{-n}$。
* **最小負數**：$-2^{m-1}$。

以 **Q8.8**（總共 16 bits）為例：

* 解析度：$2^{-8} = 0.00390625$
* 範圍：$-128.0$ 到 $+127.99609375$

### 三、 軟體浮點數與硬體 Q Format 的轉換

在將演算法（如 Python/C 寫的浮點數）轉入硬體前，必須先做數值轉換：

1. **Float 轉 Q Format (Encode)**：
將浮點數乘以 $2^n$，然後四捨五入取整數。

$$X_Q = \text{round}(X_{float} \times 2^n)$$



*例如：將 $3.14$ 轉為 Q8.8 $\rightarrow$ $\text{round}(3.14 \times 256) = 804$ (十六進位為 `16'h0324`)*。
2. **Q Format 轉 Float (Decode)**：
將硬體算出的整數除以 $2^n$。

$$X_{float} = \frac{X_Q}{2^n}$$



---
在 Verilog 實作 Q Format 的鐵則

在 Verilog 中，編譯器（Synthesizer）**完全不知道小數點在哪裡**，它只會把所有東西當作整數來算。
因此，所有的對齊與位元擴展都必須由設計者手動控制。

#### 1. 小數點對齊原則 (Alignment)
**加法與減法前，兩個運算元的小數點位置必須一模一樣！**
如果要把一個 Q8.8 的數字和一個 Q4.12 的數字相加，必須先將 Q8.8 的小數擴充為 12 bits（左移 4 位）。

```verilog
wire signed [15:0] a; // Q8.8
wire signed [15:0] b; // Q4.12

// 錯誤寫法：直接相加，小數點錯位，數值全毀
// wire signed [16:0] err_sum = a + b; 

// 正確寫法：把 a 左移 4 位變成 Q8.12 (總共 20 bits)，再與擴充後的 b 相加
wire signed [20:0] correct_sum = (a <<< 4) + b; 

```

#### 2. 有號數宣告 (`$signed`)
由於 Q Format 幾乎都是帶符號的（二補數），請務必在 Verilog 中大量使用 `signed` 宣告。
當進行右移 (`>>>`) 或擴充位元時，Verilog 才會自動幫您複製最高位的符號位（Sign Extension），避免正數變負數或負數變正數。

#### 3. 乘法位元數暴增 (Bit Growth)
兩個定點數相乘，**整數位與小數位會分別相加**。
$Q_{m1.n1} \times Q_{m2.n2} = Q_{(m1+m2).(n1+n2)}$

```verilog
wire signed [15:0] x; // Q8.8
wire signed [15:0] y; // Q8.8

// 乘積必須是 32 bits (Q16.16)
wire signed [31:0] mult_result = x * y; 

```

#### 4. 乘法後的平移與截斷 (Truncation)
乘法算出 Q16.16 之後，通常暫存器裝不下，需要轉回原本的 Q8.8。
這時候必須**向右平移捨去多餘的小數，並截斷多餘的整數**。

```verilog
// 承上題，將 Q16.16 轉回 Q8.8
// 捨去下方 8 個小數 (>> 8)，保留中間 16 bits，自動丟棄上方 8 個多餘的整數
wire signed [15:0] final_out = mult_result[23:8]; 

```

#### 5. 除法的預先平移 (Pre-shifting)
這是在硬體中最容易算成 `0` 的坑。
$Q_{m1.n1} \div Q_{m2.n2} = Q_{(m1-m2).(n1-n2)}$
如果分子的小數位不夠多，除下去結果直接變 0。必須先將分子的位元向左擴充（補零），再進行除法。

```verilog
// 計算 X (Q8.8) / Y (Q8.8)，希望結果還是 Q8.8
// 必須先把分子 X 擴充為 Q8.16，除以 Q8.8 後才會得到 Qx.8
wire signed [31:0] num_shifted = {x, 8'b0}; // 或是 x <<< 8
wire signed [15:0] div_result = num_shifted / y; 

```

#### 6. 截斷誤差 (Truncation) vs. 四捨五入 (Rounding)
在做右移（如 `>> 8`）時，本質上是「無條件捨去」(Floor)。在音訊處理或通訊系統中，一直捨去會產生嚴重的**DC Bias**。
硬體設計會在截斷前，加上要被捨棄掉的最高位（相當於加 0.5）來實現四捨五入：

```verilog
// Q16.16 轉 Q16.8 並帶有四捨五入 (加 0.5 也就是 2^7)
wire signed [31:0] rounded = mult_result + 32'h0000_0080;
wire signed [23:0] out = rounded[31:8];

```

#### 7. 溢位與飽和保護 (Saturation)
當數值加法或乘法後超出了定義的 $m$ (整數位) 範圍，在 C 語言中可能只是算錯，但在硬體中最高位（Sign bit）會反轉，導致巨大的正數瞬間變成負數（Wrap-around）。
在關鍵運算的最後一階，通常必須手動撰寫**飽和電路 (Saturation Logic)**：判斷如果發生溢位，就強制將數值鎖死在最大正數或最小負數。

*/
