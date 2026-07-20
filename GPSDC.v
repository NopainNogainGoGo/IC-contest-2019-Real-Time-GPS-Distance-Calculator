`timescale 1ns/10ps
`include "CosInterpolation.v"
`include "AsinInterpolation.v"

module GPSDC(
    input              clk,
    input              reset_n,
    input              DEN,
    input      [23:0]  LON_IN,
    input      [23:0]  LAT_IN,
    
    input      [95:0]  COS_DATA,
    output     [6:0]   COS_ADDR,
    
    input      [127:0] ASIN_DATA,
    output     [5:0]   ASIN_ADDR,
    
    output reg         Valid,
    output reg [39:0]  D,
    output reg [63:0]  a
);

localparam  IDLE        = 4'd0,
            START_COS_A = 4'd1,
            COS_A       = 4'd2,
            START_COS_B = 4'd3,
            COS_B       = 4'd4,
            CALC_A      = 4'd5,  
            START_ASIN  = 4'd6,
            ASIN        = 4'd7,
            CAL         = 4'd8,
            DONE        = 4'd9;

// 【優化】去掉前面無效的 5 個 0，縮小至 11 bits
localparam [10:0] RAD = 11'h477; 
localparam [23:0] R   = 24'd12756274;

reg [3:0] curr_state, next_state;

reg signed [23:0] A_LAT, A_LON;
reg signed [23:0] B_LAT, B_LON;

// 【優化】乘法器位寬依賴 RAD 縮減而變小
reg signed [69:0] a2, a4; 
// 【優化】Cosine 最大為 1，保留 Q2.64 共 66 bits 即可
reg signed [65:0] cosA, cosB; 

reg data_ready;

reg         cos_start;
reg  [47:0] cos_target;
wire        cos_done;
wire [95:0] cos_interp;

reg         asin_start;
wire        asin_done;
wire [127:0] asin_interp;

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
        CALC_A:      next_state = START_ASIN; 
        START_ASIN:  next_state = ASIN;
        ASIN:        next_state = asin_done ? CAL : ASIN;
        CAL:         next_state = DONE;
        DONE:        next_state = IDLE;
        default:     next_state = IDLE;    
    endcase
end

always @(posedge clk or negedge reset_n) begin
    if(!reset_n)
        data_ready <= 1'b0;
    else if(DEN)
        data_ready <= 1'b1;
end

always @(posedge clk) begin
    if(DEN) begin
        A_LAT <= B_LAT;  B_LAT <= LAT_IN;  
        A_LON <= B_LON;  B_LON <= LON_IN;
    end    
end

always @(*) begin
    cos_start  = (curr_state == START_COS_A) || (curr_state == START_COS_B);
    asin_start = (curr_state == START_ASIN);
    
    if (curr_state == START_COS_A || curr_state == COS_A)
        cos_target = {8'b0, A_LAT, 16'b0};
    else
        cos_target = {8'b0, B_LAT, 16'b0};
end

// ================== 計算 a 公式 =====================
wire [23:0] lat_max = (B_LAT >= A_LAT) ? B_LAT : A_LAT;
wire [23:0] lat_min = (B_LAT <  A_LAT) ? B_LAT : A_LAT;
wire [23:0] delta_lat = lat_max - lat_min;

wire [23:0] lon_max = (B_LON >= A_LON) ? B_LON : A_LON;
wire [23:0] lon_min = (B_LON <  A_LON) ? B_LON : A_LON;
wire [23:0] delta_lon = lon_max - lon_min;

// 【優化】24-bit * 11-bit = 35-bit
wire [34:0] a1_val = (delta_lat * RAD) >> 1; 
wire [34:0] a3_val = (delta_lon * RAD) >> 1;

// 【優化】35-bit * 35-bit = 70-bit (Q16.64)
wire [69:0] a1_sq = a1_val * a1_val; 
wire [69:0] a3_sq = a3_val * a3_val; 

always @(posedge clk) begin
    a2 <= a1_sq; 
    a4 <= a3_sq; 
end

// ==============================================================
always @(posedge clk) begin
    if (curr_state == COS_A && cos_done)
        cosA <= cos_interp[65:0]; // 擷取需要的 66 bits (Q2.64)
    else if (curr_state == COS_B && cos_done)
        cosB <= cos_interp[65:0];
end

wire signed [131:0] cos_ab_full = cosA * cosB;

// 保留 Q2.64
wire signed [65:0] cos_ab_q2_64 = cos_ab_full[129:64];

// 66×64 或 66×71
wire signed [136:0] term2 = cos_ab_q2_64 * $signed(a4);

// Q18.128 -> Q16.64
wire signed [63:0] term2_q16_64 = term2[127:64];
wire [87:0] D_temp = R * asin_interp[63:0]; 

always @(posedge clk) begin
    if (curr_state == CALC_A) begin
        a <= a2[63:0] + term2_q16_64; 
    end
    if (curr_state == CAL) begin
        D <= D_temp[71:32]; 
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

always @(posedge clk or negedge reset_n)begin
    if(!reset_n)
        Valid <= 1'b0;
    else if(next_state == DONE)
        Valid <= 1'b1;
    else
        Valid <= 1'b0;
end

endmodule
