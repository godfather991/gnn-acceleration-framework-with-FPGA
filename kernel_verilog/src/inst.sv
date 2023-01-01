// This is a generated file. Use and modify at your own risk.
//////////////////////////////////////////////////////////////////////////////// 
// Author: Kai Zhong
// Mail  : zhongkai2020@sina.com
// Date  : 2022.12.15
// Info  : Modifed from vadd example file generated by Vitis. 
//         Instruction module of gnn accelerator.
//////////////////////////////////////////////////////////////////////////////// 
// default_nettype of none prevents implicit wire declaration.
`default_nettype none

module gnn_0_example_inst #(
  parameter integer WEIT_INST_BIT_WIDTH      = 128,
  parameter integer BIAS_INST_BIT_WIDTH      = 128,
  parameter integer LOAD_INST_BIT_WIDTH      = 128,
  parameter integer SAVE_INST_BIT_WIDTH      = 128,
  parameter integer AGG_INST_BIT_WIDTH       = 128,
  parameter integer MM_INST_BIT_WIDTH        = 128,
  parameter integer C_M_AXI_ADDR_WIDTH       = 64 ,
  parameter integer C_M_AXI_DATA_WIDTH       = 512,
  parameter integer C_XFER_SIZE_WIDTH        = 32,
  parameter integer C_ADDER_BIT_WIDTH        = 32
)
(
  // System Signals
  input wire                                    aclk               ,
  input wire                                    areset             ,
  // Extra clocks
  input wire                                    kernel_clk         ,
  input wire                                    kernel_rst         ,
  // ctrl signals
  input  wire                                   ap_start           ,
  output wire                                   ap_done            ,
  input  wire [C_M_AXI_ADDR_WIDTH-1:0]          ctrl_addr_offset   ,
  // inst moudle to other modules
  output wire [WEIT_INST_BIT_WIDTH  -1:0]       instruction_to_weight ,
  output wire [BIAS_INST_BIT_WIDTH  -1:0]       instruction_to_bias   ,
  output wire [LOAD_INST_BIT_WIDTH  -1:0]       instruction_to_load   ,
  output wire [SAVE_INST_BIT_WIDTH  -1:0]       instruction_to_save   ,
  output wire [AGG_INST_BIT_WIDTH   -1:0]       instruction_to_agg    ,
  output wire [MM_INST_BIT_WIDTH    -1:0]       instruction_to_mm     ,
  output wire                                   valid_to_load         ,
  output wire                                   valid_to_weight       ,
  output wire                                   valid_to_bias         ,
  output wire                                   valid_to_agg          ,
  output wire                                   valid_to_mm           ,
  output wire                                   valid_to_save         ,
  input  wire                                   done_to_load          ,
  input  wire                                   done_to_weight        ,
  input  wire                                   done_to_bias          ,
  input  wire                                   done_to_agg           ,
  input  wire                                   done_to_mm            ,
  input  wire                                   done_to_save          ,
  // AXI4 master interface
  output wire                                   m_axi_awvalid      ,
  input wire                                    m_axi_awready      ,
  output wire [C_M_AXI_ADDR_WIDTH-1:0]          m_axi_awaddr       ,
  output wire [8-1:0]                           m_axi_awlen        ,
  output wire                                   m_axi_wvalid       ,
  input wire                                    m_axi_wready       ,
  output wire [C_M_AXI_DATA_WIDTH-1:0]          m_axi_wdata        ,
  output wire [C_M_AXI_DATA_WIDTH/8-1:0]        m_axi_wstrb        ,
  output wire                                   m_axi_wlast        ,
  output wire                                   m_axi_arvalid      ,
  input wire                                    m_axi_arready      ,
  output wire [C_M_AXI_ADDR_WIDTH-1:0]          m_axi_araddr       ,
  output wire [8-1:0]                           m_axi_arlen        ,
  input wire                                    m_axi_rvalid       ,
  output wire                                   m_axi_rready       ,
  input wire [C_M_AXI_DATA_WIDTH-1:0]           m_axi_rdata        ,
  input wire                                    m_axi_rlast        ,
  input wire                                    m_axi_bvalid       ,
  output wire                                   m_axi_bready       
);

timeunit 1ps;
timeprecision 1ps;


///////////////////////////////////////////////////////////////////////////////
// Local Parameters
///////////////////////////////////////////////////////////////////////////////
localparam integer LP_DW_BYTES             = C_M_AXI_DATA_WIDTH/8;
localparam integer LP_AXI_BURST_LEN        = 4096/LP_DW_BYTES < 256 ? 4096/LP_DW_BYTES : 256;
localparam integer LP_LOG_BURST_LEN        = $clog2(LP_AXI_BURST_LEN);
localparam integer LP_BRAM_DEPTH           = 512;
localparam integer LP_RD_MAX_OUTSTANDING   = LP_BRAM_DEPTH / LP_AXI_BURST_LEN;
localparam integer LP_WR_MAX_OUTSTANDING   = 32;

// fifo parameters
localparam integer LP_FIFO_DEPTH           = 32;
localparam integer LP_FIFO_COUNT_WIDTH     = $clog2(LP_FIFO_DEPTH)+1;
localparam integer LP_FIFO_READ_LATENCY    = 1; // 2: Registered output on BRAM, 1: Registered output on LUTRAM
// fetch and decode FSM states
localparam IDLE   = 4'b0000;
localparam ADDR   = 4'b0001;
localparam WAIT   = 4'b0010;
localparam RCEV   = 4'b0011;
localparam PRO0   = 4'b0100;
localparam PRO1   = 4'b0101;
localparam PRO2   = 4'b0110;
localparam PRO3   = 4'b0111;
localparam LAST   = 4'b1000;
localparam DONE   = 4'b1001;
// OpCode
localparam WEIGHT = 4'b1000;
localparam BIAS   = 4'b1001;
localparam LOAD   = 4'b1010;
localparam SAVE   = 4'b1011;
localparam AGG    = 4'b1100;
localparam MM     = 4'b1101;
// dispatch FSM states
localparam IDL    = 2'b00;
localparam DEP    = 2'b01;
localparam ISS    = 2'b10;
localparam RUN    = 2'b11;


///////////////////////////////////////////////////////////////////////////////
// Wires and Variables
///////////////////////////////////////////////////////////////////////////////

// xfer state logic
logic                          addr_xfer;
logic                          data_xfer;
// instruction decode logic
logic [4-1:0]                  opcode;
logic [WEIT_INST_BIT_WIDTH-1:0]instruction;

// AXI fetch FSM 
logic [4-1:0]                  state_r   ;
logic [4-1:0]                  next_state;
logic [4-1:0]                  cnt_r     ; // counter for LAST state delay to ensure last inst saved in fifo
//// Overall Control logic
//logic                          done = 1'b0;
// AXI read master stage
logic                          fetch_done    ;
logic                          fetch_start_r ;
logic [C_M_AXI_ADDR_WIDTH-1:0] fetch_addr_r  ;
logic                          rd_tvalid     ;
logic                          rd_tready     ;
logic                          rd_tlast      ;
logic [C_M_AXI_DATA_WIDTH-1:0] rd_tdata      ;

// instruction fifos state signal
logic                          all_not_full;
logic                          weight_full ;
logic                          bias_full   ;
logic                          load_full   ;
logic                          save_full   ;
logic                          agg_full    ;
logic                          mm_full     ;
logic                          all_empty   ;
logic                          weight_empty;
logic                          bias_empty  ;
logic                          load_empty  ;
logic                          save_empty  ;
logic                          agg_empty   ;
logic                          mm_empty    ;
// write read instruction fifos
logic                          weight_fifo_wren;
logic                          bias_fifo_wren  ;
logic                          load_fifo_wren  ;
logic                          save_fifo_wren  ;
logic                          agg_fifo_wren   ;
logic                          mm_fifo_wren    ;
logic                          weight_fifo_rden;
logic                          bias_fifo_rden  ;
logic                          load_fifo_rden  ;
logic                          save_fifo_rden  ;
logic                          agg_fifo_rden   ;
logic                          mm_fifo_rden    ;

// instruction dispatch state FSM
logic                          all_idle      ;
logic [2-1:0]                  weight_state_r;
logic [2-1:0]                  bias_state_r  ;
logic [2-1:0]                  load_state_r  ;
logic [2-1:0]                  save_state_r  ;
logic [2-1:0]                  agg_state_r   ;
logic [2-1:0]                  mm_state_r    ;
logic [2-1:0]                  weight_next_state;
logic [2-1:0]                  bias_next_state  ;
logic [2-1:0]                  load_next_state  ;
logic [2-1:0]                  save_next_state  ;
logic [2-1:0]                  agg_next_state   ;
logic [2-1:0]                  mm_next_state    ;

// dependency ctrl logic signal
logic                   weight_ok;
logic                   bias_ok  ;
logic                   agg_ok   ;
logic                   load_ok  ;
logic                   save_ok  ;
logic                   mm_ok    ;
// dependency ctrl register
logic [32-1 :0]         weight_after_bias ;
logic [32-1 :0]         weight_after_load ;
logic [32-1 :0]         weight_after_agg  ;
logic [32-1 :0]         weight_after_mm   ;
logic [32-1 :0]         weight_after_save ;

logic [32-1 :0]         bias_after_weight ;
logic [32-1 :0]         bias_after_load   ;
logic [32-1 :0]         bias_after_agg    ;
logic [32-1 :0]         bias_after_mm     ;
logic [32-1 :0]         bias_after_save   ;

logic [32-1 :0]         load_after_weight ;
logic [32-1 :0]         load_after_bias   ;
logic [32-1 :0]         load_after_agg    ;
logic [32-1 :0]         load_after_mm     ;
logic [32-1 :0]         load_after_save   ;

logic [32-1 :0]         save_after_weight;
logic [32-1 :0]         save_after_bias  ;
logic [32-1 :0]         save_after_load  ;
logic [32-1 :0]         save_after_agg   ;
logic [32-1 :0]         save_after_mm    ;

logic [32-1 :0]         agg_after_weight;
logic [32-1 :0]         agg_after_bias  ;
logic [32-1 :0]         agg_after_load  ;
logic [32-1 :0]         agg_after_mm    ;
logic [32-1 :0]         agg_after_save  ;

logic [32-1 :0]         mm_after_weight ;
logic [32-1 :0]         mm_after_bias   ;
logic [32-1 :0]         mm_after_load   ;
logic [32-1 :0]         mm_after_agg    ;
logic [32-1 :0]         mm_after_save   ;

///////////////////////////////////////////////////////////////////////////////
// Begin RTL
///////////////////////////////////////////////////////////////////////////////

///////////////////////////////////////////////////////////////////////////////
// fetch instructions and decode logic
///////////////////////////////////////////////////////////////////////////////

// xfer state logic
assign addr_xfer = (state_r == ADDR)    ; // address will always be sent successfully
assign data_xfer = rd_tvalid & rd_tready;
// addr xfer send logic
always @(posedge aclk) begin
  if (areset) begin
    fetch_start_r <= 0;
    fetch_addr_r  <= 0;
  end else begin
    fetch_start_r <= (state_r == ADDR); // assert start_r when state_r==ADDR
    fetch_addr_r  <= fetch_start_r ? fetch_addr_r + 64 : fetch_addr_r ; 
    // addr inc when fetch_start_r (not addr_xfer since IP will sample addr at posedge of start_r)
    // state_r==ADDR  ->  featch_start_r==1(addr received at its posedge)  ->  featch_addr_r==next
  end
end
// inst data received at data_xfer cycle
always @(posedge aclk) begin
  if (areset) begin
    input_instructions_r <= 0;
  end else if (data_xfer) begin
    input_instructions_r <= rd_tdata;
  end
end

// decode logic
assign opcode = state_r==PRO0 ? input_instructions_r[32-1  :32-4 ] :
                state_r==PRO1 ? input_instructions_r[160-1 :160-4] :
                state_r==PRO2 ? input_instructions_r[288-1 :288-4] :
                input_instructions_r[416-1 :416-4]; 
assign instruction = state_r==PRO0 ? input_instructions_r[128-1 :0] :
                     state_r==PRO1 ? input_instructions_r[256-1 :0] :
                     state_r==PRO2 ? input_instructions_r[384-1 :0] :
                     input_instructions_r[512-1 :0]; 
// send instructions to their fifo only at prcess_states
logic process_states;
assign process_states   = (state_r==PRO0)|(state_r==PRO1)|(state_r==PRO2)|(state_r==PRO3);
assign weight_fifo_wren = (opcode==WEIGHT)&process_states;
assign bias_fifo_wren   = (opcode==BIAS  )&process_states;
assign load_fifo_wren   = (opcode==LOAD  )&process_states;
assign save_fifo_wren   = (opcode==SAVE  )&process_states;
assign agg_fifo_wren    = (opcode==AGG   )&process_states;
assign mm_fifo_wren     = (opcode==MM    )&process_states;

// fifo states and issue states logic used by AXI fetch FSM
assign all_not_full = (~weight_full)&(~bias_full)&(~load_full)&(~save_full)&(~agg_full)&(~mm_full);
assign all_empty    = (weight_empty)&(bias_empty)&(load_empty)&(save_empty)&(agg_empty)&(mm_empty);
assign all_idle     = (weight_state_r==IDL)&(bias_state_r==IDL)&(load_state_r==IDL)&(save_state_r==IDL)&(agg_state_r==IDL)&(mm_state_r==IDL);

// cnt_r for LAST state delay, reset at other stage
always @(posedge aclk) begin
  if (areset) begin
    cnt_r <= 4'b0000;
  end else if (state_r==LAST) begin
    cnt_r <= cnt_r + 1;
  end else begin
    cnt_r <= 4'b0000;
  end
end

// FSM register
always @(posedge aclk) begin
  if (areset) begin
    state_r <= IDLE;
  end else begin
    state_r <= next_state;
  end
end

// FSM next state logic
always @(*) begin
    case(state_r) 
        IDLE: begin // idle state, change to addr xfer if ap_start
            next_state = ap_start ? ADDR : IDLE;
        end
        WAIT: begin // wait for all fifos not full so that next four instructions can be read 
            next_state = all_not_full ? ADDR : WAIT;
        end
        ADDR: begin // transfer read address, change to receive when addr_xfer
            next_state = addr_xfer ? RCEV : ADDR;
        end
        RCEV: begin // receive four-instrution data into instruction register if data_xfer and change to PRO0 
            next_state = data_xfer ? PRO0 : RCEV;
        end
        PRO0: begin // process input_instructions_r[128-1:0]
            next_state = opcode==4'b0000 ? LAST : PRO1;
        end
        PRO1: begin // process input_instructions_r[256-1:128]
            next_state = opcode==4'b0000 ? LAST : PRO2;
        end
        PRO2: begin // process input_instructions_r[384-1:256]
            next_state = opcode==4'b0000 ? LAST : PRO3;
        end
        PRO3: begin // process input_instructions_r[512-1:384], change to addr to read next insts if all_not_full, or WAIT
            next_state = opcode==4'b0000 ? LAST : (all_not_full ? ADDR : WAIT);
        end
        LAST: begin // LAST instruction has been read and it is time to waiting for all fifos empty
            next_state = all_empty & all_idle & cnt_r>4 ? DONE : LAST;
        end
        DONE: begin // done and ready to next
            next_state = IDLE;
        end
    endcase
end

assign ap_done = (state_r == DONE);


// AXI4 Read Master, output format is an AXI4-Stream master, one stream per thread.
gnn_0_example_axi_read_master #(
  .C_M_AXI_ADDR_WIDTH  ( C_M_AXI_ADDR_WIDTH    ) ,
  .C_M_AXI_DATA_WIDTH  ( C_M_AXI_DATA_WIDTH    ) ,
  .C_XFER_SIZE_WIDTH   ( C_XFER_SIZE_WIDTH     ) ,
  .C_MAX_OUTSTANDING   ( LP_RD_MAX_OUTSTANDING ) ,
  .C_INCLUDE_DATA_FIFO ( 1                     )
)
inst_fetch_inst (
  .aclk                    ( aclk                    ) ,
  .areset                  ( areset                  ) ,
  // ctrl port use it
  .ctrl_start              ( fetch_start             ) ,
  .ctrl_done               ( fetch_done              ) ,
  .ctrl_addr_offset        ( fetch_addr              ) ,
  .ctrl_xfer_size_in_bytes ( 7'b100_0000             ) ,
  // AXI port don't change
  .m_axi_arvalid           ( m_axi_arvalid           ) ,
  .m_axi_arready           ( m_axi_arready           ) ,
  .m_axi_araddr            ( m_axi_araddr            ) ,
  .m_axi_arlen             ( m_axi_arlen             ) ,
  .m_axi_rvalid            ( m_axi_rvalid            ) ,
  .m_axi_rready            ( m_axi_rready            ) ,
  .m_axi_rdata             ( m_axi_rdata             ) ,
  .m_axi_rlast             ( m_axi_rlast             ) ,
  .m_axis_aclk             ( kernel_clk              ) ,
  .m_axis_areset           ( kernel_rst              ) ,
  // stream port, use it
  .m_axis_tvalid           ( rd_tvalid               ) ,
  .m_axis_tready           ( rd_tready               ) ,
  .m_axis_tlast            ( rd_tlast                ) ,
  .m_axis_tdata            ( rd_tdata                )
);


///////////////////////////////////////////////////////////////////////////////
// dispatch instructions of each module
///////////////////////////////////////////////////////////////////////////////

// dispatch logic of weight moudule
// fifo
xpm_fifo_sync # (
    .FIFO_MEMORY_TYPE    ( "auto"               ) , // string; "auto", "block", "distributed", or "ultra";
    .ECC_MODE            ( "no_ecc"             ) , // string; "no_ecc" or "en_ecc";
    .FIFO_WRITE_DEPTH    ( LP_FIFO_DEPTH        ) , // positive integer
    .WRITE_DATA_WIDTH    ( C_M_AXI_DATA_WIDTH   ) , // positive integer
    .WR_DATA_COUNT_WIDTH ( LP_FIFO_COUNT_WIDTH  ) , // positive integer, not used
    .PROG_FULL_THRESH    ( 10                   ) , // positive integer
    .FULL_RESET_VALUE    ( 1                    ) , // positive integer; 0 or 1
    .USE_ADV_FEATURES    ( "1F1F"               ) , // string; "0000" to "1F1F";
    .READ_MODE           ( "std"                ) , // string; "std" or "fwft";
    .FIFO_READ_LATENCY   ( LP_FIFO_READ_LATENCY ) , // positive integer;
    .READ_DATA_WIDTH     ( C_M_AXI_DATA_WIDTH   ) , // positive integer
    .RD_DATA_COUNT_WIDTH ( LP_FIFO_COUNT_WIDTH  ) , // positive integer, not used
    .PROG_EMPTY_THRESH   ( 10                   ) , // positive integer, not used
    .DOUT_RESET_VALUE    ( "0"                  ) , // string, don't care
    .WAKEUP_TIME         ( 0                    ) // positive integer; 0 or 2;
) inst_fifo_weight (
    .sleep         ( 1'b0                        ) ,
    .rst           ( areset                      ) ,
    .wr_clk        ( aclk                        ) ,
    .wr_en         ( weight_fifo_wren            ) ,
    .din           ( instruction                 ) ,
    .prog_full     ( weight_full                 ) ,
    .rd_en         ( weight_rd_en                ) ,
    .dout          ( instruction_to_weight       ) ,
    .empty         ( weight_empty                ) ,
    .data_valid    ( rd_weight_valid             ) ,
    .injectsbiterr ( 1'b0                        ) ,
    .injectdbiterr ( 1'b0                        )
) ;
// FSM of weight module
always @(posedge aclk) begin
    if (areset) begin
        weight_state_r <= 0;
    end else begin
        weight_state_r <= weight_next_state;
    end
end
always @(*) begin
    case (weight_state_r) 
        IDL: begin
            weight_next_state = (~weight_empty) ? RDF : IDL;
        end
        RDF: begin
            weight_next_state = DEP; 
        end
        DEP: begin
            weight_next_state = (weight_ok) ? ISS : DEP; 
        end
        ISS: begin
            weight_next_state = RUN;
        end
        RUN: begin
            weight_next_state = (done_from_weight) ? DON : RUN;
        end
        DON: begin
            weight_next_state = (~weight_empty) ? RDF : IDL;
        end
    endcase
end
// dispatch of weight instruction
assign weight_rd_en    = (weight_state_r == RDF) ? 1'b1; 1'b0;  // only rd fifo at RDF stage
assign valid_to_weight = (weight_state_r == ISS) ? 1'b1; 1'b0;  // issue instruction at ISS stage
assign weight_ok       = 

endmodule : gnn_0_example_inst
`default_nettype wire
