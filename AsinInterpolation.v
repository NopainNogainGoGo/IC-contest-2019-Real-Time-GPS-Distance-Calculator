module AsinInterpolation(
    input              clk,
    input              reset_n,
    input              start,

    input      [63:0]  target, 

    output reg [5:0]   ASIN_ADDR,
    input      [127:0] ASIN_DATA,

    output reg         done,
    output reg signed [127:0] asin_interp
);

localparam DIV_STAGES = 14; // 管線級數，可視 Timing 需求調整

localparam  IDLE     = 4'd0,
            SEARCH   = 4'd1,
            REQ_L    = 4'd2,
            READ_L   = 4'd3,
            READ_H   = 4'd4,
            PIPE_1   = 4'd5,
            PIPE_2   = 4'd6,
            PIPE_3   = 4'd7,
            WAIT_DIV = 4'd8; 

reg [3:0] bs_curr_state, bs_next_state;
reg [4:0] wait_cnt; // 用於等待管線化除法器的固定延遲

reg [5:0] low, high;
reg [5:0] low_next, high_next;

reg signed [64:0] x0, x1;
reg signed [64:0] y0, y1;

// --- Pipeline Stage 1: 減法暫存器 ---
// 65 bit 相減，為了防溢位給 66 bit
reg signed [65:0] dx_reg;
reg signed [65:0] dx1_reg;
reg signed [65:0] dy_reg;
reg signed [64:0] y0_reg;      

// --- Pipeline Stage 2: 乘法暫存器 ---
// 66 bit * 66 bit = 132 bit
reg signed [131:0] term1_reg;
reg signed [131:0] term2_reg;
reg signed [65:0] dx1_reg2;   

// --- Pipeline Stage 3: 加法暫存器 ---
// 132 bit 相加，給 133 bit
reg signed [132:0] numerator_reg; 
reg signed [65:0] dx1_reg3;

// --- DesignWare 除法器輸出訊號 ---
wire div_by_0;
wire signed [132:0] div_quotient;
wire signed [65:0]  div_remainder;

// ========================================================
// 實例化 Synopsys DW_div_pipe
// ========================================================
DW_div_pipe #(
    .a_width(133),         // 被除數位元寬度 (numerator_reg)
    .b_width(66),          // 除數位元寬度 (dx1_reg3)
    .tc_mode(1),           // 1: 有號數 (Signed) 運算
    .rem_mode(1),          // 1: 餘數符號跟隨除數
    .num_stages(DIV_STAGES), 
    .stall_mode(1),        
    .rst_mode(0),          
    .op_iso_mode(0)        
) u_dw_div_pipe (
    .clk(clk),
    .rst_n(reset_n),
    .en(1'b1),            
    .a(numerator_reg),
    .b(dx1_reg3), 
    .quotient(div_quotient),
    .remainder(div_remainder),
    .divide_by_0(div_by_0)
);

// --------------------------------------------------------
// Pipeline 運算 (Stage 1 ~ 3)
// --------------------------------------------------------
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        dx_reg        <= 66'sd0;
        dx1_reg       <= 66'sd0;
        dy_reg        <= 66'sd0;
        y0_reg        <= 65'sd0;
        
        term1_reg     <= 132'sd0;
        term2_reg     <= 132'sd0;
        dx1_reg2      <= 66'sd0;
        
        numerator_reg <= 133'sd0;
        dx1_reg3      <= 66'sd0; 
    end else begin
        // [Stage 1] 
        dx_reg  <= $signed({1'b0, target}) - x0;
        dx1_reg <= x1 - x0;
        dy_reg  <= y1 - y0;
        y0_reg  <= y0;            

        // [Stage 2] Q0.64 * Q0.64 = Q0.128
        term1_reg <= y0_reg * dx1_reg;
        term2_reg <= dx_reg * dy_reg;
        dx1_reg2  <= dx1_reg;      

        // [Stage 3] 直接相加即可，兩者皆為 Q0.128，無需任何左移 (<<<)
        numerator_reg <= term1_reg + term2_reg;
        dx1_reg3      <= dx1_reg2; 
    end
end

always @(*) begin
    case(bs_curr_state)
        IDLE:      bs_next_state = start ? SEARCH : IDLE;
        SEARCH:    bs_next_state = ((high - low) == 6'd1) ? REQ_L : SEARCH;
        REQ_L:     bs_next_state = READ_L;
        READ_L:    bs_next_state = READ_H;
        READ_H:    bs_next_state = PIPE_1; 
        PIPE_1:    bs_next_state = PIPE_2; 
        PIPE_2:    bs_next_state = PIPE_3; 
        PIPE_3:    bs_next_state = WAIT_DIV; // 資料已送入除法器，進入等待
        WAIT_DIV:  bs_next_state = (wait_cnt == 5'd1) ? IDLE : WAIT_DIV;
        default:   bs_next_state = IDLE;
    endcase
end

always @(*) begin
    low_next  = low;
    high_next = high;
    if({1'b0, target} < {1'b0, ASIN_DATA[127:64]}) begin
        high_next = ASIN_ADDR;
    end else begin
        low_next = ASIN_ADDR;
    end
end

always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
        bs_curr_state <= IDLE;
        low        <= 0;
        high       <= 63;
        ASIN_ADDR  <= 31;
        done       <= 0;
        asin_interp  <= 0;
        wait_cnt   <= 0;
    end else begin
        bs_curr_state <= bs_next_state;
        done       <= 0; 
        
        case(bs_curr_state)
            IDLE: begin
                if(start) begin
                    low      <= 0;
                    high     <= 63;
                    ASIN_ADDR <= 31;
                end
            end

            SEARCH: begin
                low      <= low_next;
                high     <= high_next;
                ASIN_ADDR <= ({1'b0, low_next} + {1'b0, high_next}) >> 1;
            end

            REQ_L: begin
                ASIN_ADDR <= low; 
            end

            READ_L: begin
                // 強制在最前面補 1'b0，確保 64 bit 的分數不會變成負數
                x0 <= $signed({1'b0, ASIN_DATA[127:64]});
                y0 <= $signed({1'b0, ASIN_DATA[63:0]});
                ASIN_ADDR <= high; 
            end

            READ_H: begin
                x1 <= $signed({1'b0, ASIN_DATA[127:64]});
                y1 <= $signed({1'b0, ASIN_DATA[63:0]});
            end
            
            PIPE_3: begin
                wait_cnt <= DIV_STAGES; 
            end

            WAIT_DIV: begin
                if (wait_cnt == 5'd1) begin
                    asin_interp <= div_quotient[127:0]; 
                    done       <= 1'b1;
                end else if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end
            end 
        endcase
    end
end

endmodule
