`timescale 1ns/10ps
`include "/home/stu004/verilog/2019/CosInterpolation.v"
`include "/home/stu004/verilog/2019/AsinInterpolation.v"
module GPSDC(
    input              clk,
    input              reset_n,
    input              DEN,
    input      [23:0]  LON_IN,
    input      [23:0]  LAT_IN,
    
    // Cosine ROM 
    input      [95:0]  COS_DATA,
    output  [6:0]   COS_ADDR,
    
    // Arcsine ROM 
    input      [127:0] ASIN_DATA,
    output  [5:0]   ASIN_ADDR,
    
    output reg         Valid,
    output reg [39:0]  D,
    output reg [63:0]  a
);

localparam  IDLE        = 4'd0,
            START_COS_A = 4'd1,
            COS_A       = 4'd2,
            START_COS_B = 4'd3,
            COS_B       = 4'd4,
            CALC_A      = 4'd5,  // 等待計算 a = a2 + cosA*cosB*a4
            START_ASIN  = 4'd6,
            ASIN        = 4'd7,
            CAL         = 4'd8,
            DONE        = 4'd9;

localparam [15:0] RAD = 16'h0477;
localparam [23:0] R   = 24'd12756274;

reg [3:0] curr_state, next_state;

reg signed [23:0] A_LAT, A_LON;
reg signed [23:0] B_LAT, B_LON;

reg signed [79:0] a2, a4; 
reg signed [95:0] cosA, cosB;

reg data_ready;

// Cosine 內插控制訊號
reg         cos_start;
reg  [47:0] cos_target;
wire        cos_done;
wire [95:0] cos_interp;

// ASIN 內插控制訊號 
reg         asin_start;
wire        asin_done;
wire [127:0] asin_interp;

// FSM
always @(posedge clk or negedge reset_n) begin
    if(!reset_n)
        curr_state <= IDLE;
    else
        curr_state <= next_state;    
end

always @(*) begin
    case(curr_state)
        IDLE:        next_state = (DEN & data_ready) ? START_COS_A : IDLE;
        
        START_COS_A: next_state = COS_A;
        COS_A:       next_state = cos_done ? START_COS_B : COS_A;
        
        START_COS_B: next_state = COS_B;
        COS_B:       next_state = cos_done ? CALC_A : COS_B;
        
        CALC_A:      next_state = START_ASIN; // 等待 1 cycle 讓 a 計算完成 
        
        START_ASIN:  next_state = ASIN;
        ASIN:        next_state = asin_done ? CAL : ASIN;
        
        CAL:         next_state = DONE;
        DONE:        next_state = IDLE;
        default:     next_state = IDLE;    
    endcase
end

// 第一筆資料還不能運算，要等第二筆
always @(posedge clk or negedge reset_n) begin
    if(!reset_n)
        data_ready <= 1'b0;
    else if(DEN)
        data_ready <= 1'b1;
end

// shift reg 儲存 A, B 點座標
always @(posedge clk) begin
    if(DEN) begin
        A_LAT <= B_LAT;  B_LAT <= LAT_IN;  
        A_LON <= B_LON;  B_LON <= LON_IN;
    end    
end


// 產生 start pulse 給 sub-modules
always @(*) begin
    cos_start  = (curr_state == START_COS_A) || (curr_state == START_COS_B);
    asin_start = (curr_state == START_ASIN);
    
    // 依據狀態切換 Cosine x 的值
    if (curr_state == START_COS_A || curr_state == COS_A)
        cos_target = {8'b0, A_LAT, 16'b0};    // Q8.16 -> Q16.32
    else
        cos_target = {8'b0, B_LAT, 16'b0};
end

// ================== 計算 a 公式 ((B − A) ∗ rad)/2)^2 =====================
// 取得經緯度絕對差值，相減結果必定為正數
wire [23:0] lat_max = (B_LAT >= A_LAT) ? B_LAT : A_LAT;
wire [23:0] lat_min = (B_LAT <  A_LAT) ? B_LAT : A_LAT;
wire [23:0] delta_lat = lat_max - lat_min;

wire [23:0] lon_max = (B_LON >= A_LON) ? B_LON : A_LON;
wire [23:0] lon_min = (B_LON <  A_LON) ? B_LON : A_LON;
wire [23:0] delta_lon = lon_max - lon_min;

// 因為差值為正數，直接右移
wire [39:0] a1_val = (delta_lat * RAD) >> 1; 
wire [39:0] a3_val = (delta_lon * RAD) >> 1;

// 計算平方
wire [79:0] a1_sq = a1_val * a1_val; 
wire [79:0] a3_sq = a3_val * a3_val; 

always @(posedge clk) begin
    a2 <= a1_sq; 
    a4 <= a3_sq; 
end
// ==============================================================

// 儲存 cosA 與 cosB
always @(posedge clk) begin
    if (curr_state == COS_A && cos_done)
        cosA <= cos_interp;      
    else if (curr_state == COS_B && cos_done)
        cosB <= cos_interp;
end

// 計算 a 與 D
// cosA 與 cosB 都是 Q32.64 (96 bits) -> 相乘為 Q64.128 (192 bits)
wire signed [191:0] cos_ab_full = cosA * cosB;  

// 將 192 bit 的 cos_ab 與 80 bit 的 a4 直接相乘 
// Q64.128 * Q16.64 = Q80.192 (272 bits)
wire signed [271:0] term2_giant = cos_ab_full * a4;

// 從 Q80.192 擷取出 Q16.64
wire signed [79:0] term2_q16_64 = term2_giant[207:128];
wire [87:0] D_temp = R * asin_interp[63:0]; // Q24.64 = Q24.0 * Q0.64(取函數值)

always @(posedge clk) begin
    if (curr_state == CALC_A) begin
        // 兩者皆為 Q16.64，相加後直接取底部 64 bit 即為對齊的 Q0.64 
        a <= a2[63:0] + term2_q16_64[63:0]; 
    end
    
    if (curr_state == CAL) begin
        D <= D_temp[71:32]; // Q24.64 -> Q8.32
    end
end

CosInterpolation u_cos (
    .clk       (clk),
    .reset_n   (reset_n),
    .start     (cos_start),
    .target    (cos_target),
    .COS_ADDR  (COS_ADDR),
    .COS_DATA  (COS_DATA),
    .done      (cos_done),
    .cos_interp (cos_interp)
);

AsinInterpolation u_asin (
    .clk        (clk),
    .reset_n    (reset_n),
    .start      (asin_start),
    .target     (a),
    .ASIN_ADDR  (ASIN_ADDR),
    .ASIN_DATA  (ASIN_DATA),
    .done       (asin_done),
    .asin_interp (asin_interp)
);

// valid
always @(posedge clk or negedge reset_n)begin
    if(!reset_n)
        Valid <= 1'b0;
    else if(next_state == DONE)
        Valid <= 1'b1;
    else
        Valid <= 1'b0;
end

endmodule
