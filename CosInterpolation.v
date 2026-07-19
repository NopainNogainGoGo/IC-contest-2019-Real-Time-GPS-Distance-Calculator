module CosInterpolation(
    input              clk,
    input              reset_n,
    input              start,

    input  signed [47:0] target, 

    output reg  [6:0]  COS_ADDR,
    input       [95:0] COS_DATA,

    output reg         done,
    output reg signed [95:0] cos_interp
);

// 調整 DIV_STAGES 優化 Timing。
// 數字越大，Timing 越容易過；但所需的總 Cycles 也會增加。
localparam DIV_STAGES = 10; 

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

reg [6:0] low, high;
reg [6:0] low_next, high_next;

reg signed [47:0] x0, x1;
reg signed [47:0] y0, y1;

// --- Pipeline Stage 1: 減法暫存器 ---
reg signed [48:0] dx_reg;
reg signed [48:0] dx1_reg;
reg signed [48:0] dy_reg;
reg signed [47:0] y0_reg;      

// --- Pipeline Stage 2: 乘法暫存器 ---
reg signed [97:0] term1_reg;
reg signed [97:0] term2_reg;
reg signed [48:0] dx1_reg2;   

// --- Pipeline Stage 3: 加法暫存器 ---
reg signed [130:0] numerator_reg; 
reg signed [48:0] dx1_reg3;

// --- DesignWare 除法器輸出訊號 ---
wire div_by_0;
wire signed [130:0] div_quotient;
wire signed [48:0]  div_remainder;

// ========================================================
// 實例化 Synopsys DW_div_pipe
// ========================================================
DW_div_pipe #(
    .a_width(131),         // 被除數位元
    .b_width(49),          // 除數位元
    .tc_mode(1),           // 1: Signed
    .rem_mode(1),          // 1: 餘數符號跟隨除數 (通常設 1)
    .num_stages(DIV_STAGES), // 管線級數，直接影響 Timing 與 Latency
    .stall_mode(1),        // 1: Stallable 管線化模式
    .rst_mode(0),          // 0: 非同步 Reset
    .op_iso_mode(0)        // 0: 關閉操作隔離
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
// Pipeline (Stage 1 ~ 3)
// --------------------------------------------------------
always @(posedge clk) begin
        // [Stage 1] 
        dx_reg  <= target - x0;
        dx1_reg <= x1 - x0;
        dy_reg  <= y1 - y0;
        y0_reg  <= y0;            

        // [Stage 2] 
        term1_reg <= y0_reg * dx1_reg;   
        term2_reg <= dx_reg * dy_reg;    
        dx1_reg2  <= dx1_reg;       

        // [Stage 3] 
        numerator_reg <= {term1_reg[97], term1_reg} + {term2_reg[97], term2_reg} <<< 32;
        dx1_reg3      <= dx1_reg2; 
end

// --------------------------------------------------------
// FSM nx
// --------------------------------------------------------
always @(*) begin
    case(bs_curr_state)
        IDLE:      bs_next_state = start ? SEARCH : IDLE;
        SEARCH:    bs_next_state = ((high - low) == 7'd1) ? REQ_L : SEARCH;
        REQ_L:     bs_next_state = READ_L;
        READ_L:    bs_next_state = READ_H;
        READ_H:    bs_next_state = PIPE_1; 
        PIPE_1:    bs_next_state = PIPE_2; 
        PIPE_2:    bs_next_state = PIPE_3; 
        PIPE_3:    bs_next_state = WAIT_DIV; // 資料已經餵入除法器，進入等待狀態
        WAIT_DIV:  bs_next_state = (wait_cnt == 5'd1) ? IDLE : WAIT_DIV; // 等待管線延遲結束
        default:   bs_next_state = IDLE;
    endcase
end

always @(*) begin
    low_next  = low;
    high_next = high;
    if(target < $signed(COS_DATA[95:48])) begin
        high_next = COS_ADDR;
    end else begin
        low_next = COS_ADDR;
    end
end

// --------------------------------------------------------
// FSM cs + output
// --------------------------------------------------------
always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
        bs_curr_state <= IDLE;
        low        <= 0;
        high       <= 127;
        COS_ADDR   <= 63;
        done       <= 0;
        cos_interp <= 0;
        wait_cnt   <= 0;
    end else begin
        bs_curr_state <= bs_next_state;
        done       <= 0; 
        
        case(bs_curr_state)
            IDLE: begin
                if(start) begin
                    low      <= 0;
                    high     <= 127;
                    COS_ADDR <= 63;
                end
            end

            SEARCH: begin
                low      <= low_next;
                high     <= high_next;
                COS_ADDR <= ({1'b0, low_next} + {1'b0, high_next}) >> 1;
            end

            REQ_L: begin
                COS_ADDR <= low; 
            end

            READ_L: begin
                x0 <= COS_DATA[95:48];
                y0 <= COS_DATA[47:0];
                COS_ADDR <= high; 
            end

            READ_H: begin
                x1 <= COS_DATA[95:48];
                y1 <= COS_DATA[47:0];
            end

            PIPE_3: begin
                // 在這一個 Clock，numerator_reg 已經準備好並輸入到 DW_div_pipe 了
                // 初始化等待計數器，準備等待 DIV_STAGES 個 cycles
                wait_cnt <= DIV_STAGES; 
            end

            WAIT_DIV: begin
                // 當 wait_cnt 倒數到 1 的這個週期，表示下個正緣除法器的輸出就抵達了
                if (wait_cnt == 5'd1) begin
                    cos_interp <= div_quotient[95:0]; 
                    done       <= 1'b1;
                end else if (wait_cnt > 0) begin
                    wait_cnt <= wait_cnt - 1;
                end
            end 
        endcase
    end
end

endmodule
