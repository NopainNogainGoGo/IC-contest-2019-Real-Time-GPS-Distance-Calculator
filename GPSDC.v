`timescale 1ns/10ps
`include "InterpolationCore.v"

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

localparam  IDLE        = 5'd0,
            START_COS_A = 5'd1,
            COS_A       = 5'd2,
            START_COS_B = 5'd3,
            COS_B       = 5'd4,

            CALC0       = 5'd5,   // delta_lat * RAD
            CALC1       = 5'd6,   // delta_lon * RAD
            CALC2       = 5'd7,   // a1*a1
            CALC3       = 5'd8,   // a3*a3
            CALC4       = 5'd9,   // cosA*cosB
            CALC5       = 5'd10,  // cos_ab*a4
            CALC6       = 5'd11,  // a=a2+term2

            START_ASIN  = 5'd12,
            ASIN        = 5'd13,
            CALC7       = 5'd14,  
            CALC8       = 5'd15,  // R*asin
            DONE        = 5'd16;

localparam [10:0] RAD = 11'h477; 
localparam [23:0] R   = 24'd12756274;

reg [4:0] curr_state, next_state;

reg signed [23:0] A_LAT, A_LON;
reg signed [23:0] B_LAT, B_LON;

reg signed [65:0] cosA, cosB; 

reg data_ready;

reg         start;
wire        done;
wire [127:0] interp;

wire mode;
localparam MODE_COS  = 1'b0, MODE_ASIN = 1'b1;

assign mode = (curr_state == START_ASIN || curr_state == ASIN);

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
        COS_A:       next_state = done ? START_COS_B : COS_A;
        START_COS_B: next_state = COS_B;
        COS_B      : next_state = done ? CALC0 : COS_B;
        CALC0      : next_state = CALC1;
        CALC1      : next_state = CALC2;
        CALC2      : next_state = CALC3;
        CALC3      : next_state = CALC4;
        CALC4      : next_state = CALC5;
        CALC5      : next_state = CALC6;
        CALC6      : next_state = START_ASIN;
        START_ASIN : next_state = ASIN;
        ASIN       : next_state = done ? CALC7 : ASIN;
        CALC7      : next_state = CALC8;
        CALC8      : next_state = DONE;
        DONE       : next_state = IDLE;
        default:     next_state = IDLE;    
    endcase
end

reg signed [69:0] mul_operand_a;
reg signed [69:0] mul_operand_b;

wire signed [139:0] mul_result;
assign mul_result = mul_operand_a * mul_operand_b;

reg signed [34:0] a1_val;
reg signed [34:0] a3_val;

reg signed [69:0] a2;
reg signed [69:0] a4;

reg signed [65:0] cos_ab_q2_64;
reg signed [63:0] term2_q16_64;

wire [23:0] lat_max = (B_LAT >= A_LAT) ? B_LAT : A_LAT;
wire [23:0] lat_min = (B_LAT <  A_LAT) ? B_LAT : A_LAT;
wire [23:0] delta_lat = lat_max - lat_min;

wire [23:0] lon_max = (B_LON >= A_LON) ? B_LON : A_LON;
wire [23:0] lon_min = (B_LON <  A_LON) ? B_LON : A_LON;
wire [23:0] delta_lon = lon_max - lon_min;

always @(posedge clk) begin
        case (curr_state)
            CALC0: begin
                mul_operand_a <= delta_lat;
                mul_operand_b <= RAD;
            end
            CALC1: begin
                a1_val        <= mul_result[35:1];
                mul_operand_a <= delta_lon;
                mul_operand_b <= RAD;
            end
            CALC2: begin
                a3_val        <= mul_result[35:1];
                mul_operand_a <= a1_val;
                mul_operand_b <= a1_val;
            end
            CALC3: begin
                a2            <= mul_result[69:0];
                mul_operand_a <= a3_val;
                mul_operand_b <= a3_val;
            end
            CALC4: begin
                a4            <= mul_result[69:0];
                mul_operand_a <= cosA;
                mul_operand_b <= cosB;
            end
            CALC5: begin
                cos_ab_q2_64  <= mul_result[129:64];
                mul_operand_a <= mul_result[129:64];
                mul_operand_b <= a4;
            end
            CALC6: begin
                term2_q16_64 <= mul_result[127:64];
                a            <= a2[63:0] + mul_result[127:64];
            end
            CALC7: begin
                mul_operand_a <= R;
                mul_operand_b <= interp[63:0];
            end
            CALC8: begin
                D <= mul_result[71:32];
            end
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

reg [63:0] target_cos;
always @(*) begin
    start  = (curr_state == START_COS_A) || (curr_state == START_COS_B) || (curr_state == START_ASIN);
    
    if (curr_state == START_COS_A || curr_state == COS_A)
        target_cos = {24'b0, A_LAT, 16'b0};
    else
        target_cos = {24'b0, B_LAT, 16'b0};
end

always @(posedge clk) begin
    if (curr_state == COS_A && done)
        cosA <= {interp[33:0], 32'b0};
    else if (curr_state == COS_B && done)
        cosB <= {interp[33:0], 32'b0};
end

wire [6:0]   interp_addr;
wire [127:0] interp_data;
reg  [63:0]  interp_target;

always @(*) begin
    if (mode == MODE_ASIN)
        interp_target = a;
    else if (curr_state == START_COS_A || curr_state == COS_A)
        interp_target = {24'd0, A_LAT, 16'd0};
    else
        interp_target = {24'd0, B_LAT, 16'd0};
end

assign interp_data = (mode == MODE_ASIN) ? ASIN_DATA : {16'd0, COS_DATA[95:48], 16'd0, COS_DATA[47:0]};
assign COS_ADDR  = interp_addr;
assign ASIN_ADDR = interp_addr[5:0];

InterpolationCore u_interp(
    .clk(clk),
    .reset_n(reset_n),
    .start(start),
    .mode(mode),
    .target(interp_target),
    .ADDR(interp_addr),
    .DATA(interp_data),
    .done(done),
    .interp(interp)
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
