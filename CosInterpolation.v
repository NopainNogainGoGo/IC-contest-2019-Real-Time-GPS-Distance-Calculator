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

localparam  IDLE     = 4'd0,
            SEARCH   = 4'd1,
            READ_L   = 4'd2,
            READ_H   = 4'd3,
            PIPE_1   = 4'd4,
            PIPE_2   = 4'd5,
            PIPE_3   = 4'd6,
            START_DIV = 4'd7,
            WAIT_DIV = 4'd8;

reg [3:0] bs_curr_state, bs_next_state;

reg [6:0] low, high;
reg [6:0] low_next, high_next;

reg signed [47:0] x0, x1;
reg signed [47:0] y0, y1;

wire signed [48:0] full_dx  = target - x0;
wire signed [48:0] full_dx1 = x1 - x0;
wire signed [48:0] full_dy  = y1 - y0;

reg signed [20:0] dx_reg;
reg signed [20:0] dx1_reg;
reg signed [25:0] dy_reg;
reg signed [48:0] y0_reg;      

reg signed [69:0] term1_reg;
reg signed [46:0] term2_reg;
reg signed [20:0] dx1_reg2;   

reg signed [102:0] numerator_reg; 
reg signed [20:0]  dx1_reg3;

wire signed [70:0] sum_terms = {term1_reg[69], term1_reg} + {term2_reg[46], term2_reg};

wire div_by_0;
wire signed [102:0] div_quotient;
wire signed [20:0]  div_remainder;

// 替換為 Sequencial Divider，面積更小
wire div_complete;
reg  div_start;

DW_div_seq #(
    .a_width    (103),
    .b_width    (21),
    .tc_mode    (1),
    .num_cyc    (32),   // 可再調大，Area 更小
    .rst_mode   (0),
    .input_mode (1),
    .output_mode(1),
    .early_start(0)
) u_div (
    .clk(clk),
    .rst_n(reset_n),
    .hold(1'b0),
    .start(div_start),
    .a(numerator_reg),
    .b(dx1_reg3),
    .complete(div_complete),
    .quotient(div_quotient),
    .remainder(div_remainder),
    .divide_by_0(div_by_0)
);

always @(posedge clk) begin
    dx_reg  <= full_dx[20:0];
    dx1_reg <= full_dx1[20:0];
    dy_reg  <= full_dy[25:0];
    y0_reg  <= {1'b0, y0}; 

    term1_reg <= y0_reg * dx1_reg;   
    term2_reg <= dx_reg * dy_reg;    
    dx1_reg2  <= dx1_reg;       

    numerator_reg <= sum_terms <<< 32;
    dx1_reg3      <= dx1_reg2; 
end

always @(*) begin
    case(bs_curr_state)
        IDLE:      bs_next_state = start ? SEARCH : IDLE;
        SEARCH:    bs_next_state = ((high - low) == 7'd1) ? READ_L : SEARCH;
        READ_L:    bs_next_state = READ_H;
        READ_H:    bs_next_state = PIPE_1; 
        PIPE_1:    bs_next_state = PIPE_2; 
        PIPE_2:    bs_next_state = PIPE_3; 
        PIPE_3:    bs_next_state = START_DIV; 
        START_DIV:  bs_next_state = WAIT_DIV; 
        WAIT_DIV:  bs_next_state = div_complete ? IDLE : WAIT_DIV; 
        default:   bs_next_state = IDLE;
    endcase
end

// 產生 start 訊號給 DW_div_seq (維持一個 clock 的 high)
always @(*) begin
    if (bs_curr_state == START_DIV)
        div_start = 1'b1;
    else
        div_start = 1'b0;
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

always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
        bs_curr_state <= IDLE;
        low        <= 0;
        high       <= 127;
        COS_ADDR   <= 63;
        done       <= 0;
        cos_interp <= 0;
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
                if ((high - low) == 7'd1) begin
                    COS_ADDR <= low;
                end else begin
                    low      <= low_next;
                    high     <= high_next;
                    COS_ADDR <= ({1'b0, low_next} + {1'b0, high_next}) >> 1;
                end
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
            WAIT_DIV: begin
                // 改為偵測 complete 訊號
                if (div_complete) begin
                    cos_interp <= {{10{div_quotient[85]}}, div_quotient[85:0]};
                    done       <= 1'b1;
                end 
            end 
        endcase
    end
end
endmodule
