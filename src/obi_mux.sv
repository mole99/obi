// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Michael Rogenmoser <michaero@iis.ee.ethz.ch>

/// An OBI multiplexer.
module obi_mux #(
  /// The configuration of the subordinate ports (input ports).
  parameter obi_pkg::obi_cfg_t SbrPortObiCfg      = obi_pkg::ObiDefaultConfig,
  /// The configuration of the manager port (output port).
  parameter obi_pkg::obi_cfg_t MgrPortObiCfg      = SbrPortObiCfg,
  /// The request struct for the subordinate ports (input ports).
  parameter type               sbr_port_obi_req_t = logic,
  /// The A channel struct for the subordinate ports (input ports).
  parameter type               sbr_port_a_chan_t  = logic,
  /// The response struct for the subordinate ports (input ports).
  parameter type               sbr_port_obi_rsp_t = logic,
  /// The R channel struct for the subordinate ports (input ports).
  parameter type               sbr_port_r_chan_t  = logic,
  /// The request struct for the manager port (output port).
  parameter type               mgr_port_obi_req_t = sbr_port_obi_req_t,
  /// The response struct for the manager ports (output ports).
  parameter type               mgr_port_obi_rsp_t = sbr_port_obi_rsp_t,
  /// The number of subordinate ports (input ports).
  parameter int unsigned       NumSbrPorts        = 32'd0,
  /// The maximum number of outstanding transactions.
  parameter int unsigned       NumMaxTrans        = 32'd0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,

  input  sbr_port_obi_req_t [NumSbrPorts-1:0] sbr_ports_obi_req_i,
  output sbr_port_obi_rsp_t [NumSbrPorts-1:0] sbr_ports_obi_rsp_o,

  output mgr_port_obi_req_t                   mgr_port_obi_req_o,
  input  mgr_port_obi_rsp_t                   mgr_port_obi_rsp_i
);
  if (NumSbrPorts <= 1) begin
    $fatal(1, "unimplemented");
  end

  localparam RequiredExtraIdWidth = $clog2(NumSbrPorts);

  logic [NumSbrPorts-1:0] sbr_ports_req, sbr_ports_gnt;
  sbr_port_a_chan_t [NumSbrPorts-1:0] sbr_ports_a;
  for (genvar i = 0; i < NumSbrPorts; i++) begin : gen_sbr_assign
    assign sbr_ports_req[i] = sbr_ports_obi_req_i[i].req;
    assign sbr_ports_a[i] = sbr_ports_obi_req_i[i].a;
    assign sbr_ports_obi_rsp_o[i].gnt = sbr_ports_gnt[i];
  end

  sbr_port_a_chan_t mgr_port_a_in_sbr;
  logic [RequiredExtraIdWidth-1:0] selected_id, response_id;
  logic mgr_port_req, fifo_full, fifo_pop;

  rr_arb_tree #(
    .NumIn     ( NumSbrPorts ),
    .DataType  ( sbr_port_a_chan_t ),
    .AxiVldRdy ( 1'b1 ),
    .LockIn    ( 1'b1 )
  ) i_rr_arb (
    .clk_i,
    .rst_ni,

    .flush_i ( 1'b0 ),
    .rr_i    ( '0 ),

    .req_i   ( sbr_ports_req ),
    .gnt_o   ( sbr_ports_gnt ),
    .data_i  ( sbr_ports_a   ),

    .req_o   ( mgr_port_req ),
    .gnt_i   ( mgr_port_obi_rsp_i.gnt && ~fifo_full ),
    .data_o  ( mgr_port_a_in_sbr ),

    .idx_o   ( selected_id )
  );

  assign mgr_port_obi_req_o.req = mgr_port_req && ~fifo_full;

  if (MgrPortObiCfg.IdWidth > 0 && (MgrPortObiCfg.IdWidth >= SbrPortObiCfg.IdWidth + RequiredExtraIdWidth)) begin
    $fatal(1, "unimplemented");

    // assign mgr_port_obi_req_o.a.addr = mgr_port_a_in_sbr.addr;
    // assign mgr_port_obi_req_o.a.we = mgr_port_a_in_sbr.we;
    // assign mgr_port_obi_req_o.a.be = mgr_port_a_in_sbr.be;
    // assign mgr_port_obi_req_o.a.wdata = mgr_port_a_in_sbr.wdata;
    // if (MgrPortObiCfg.AUserWidth) begin
    //   assign mgr_port_obi_req_o.a.a_optional.auser = mgr_port_a_in_sbr.a_optional.auser;
    // end
    // if (MgrPortObiCfg.WUserWidth) begin
    //   assign mgr_port_obi_req_o.a.a_optional.wuser = mgr_port_a_in_sbr.a_optional.wuser;
    // end

    // assign mgr_port_obi_req_o.a.a_optional = 
  end else begin : gen_no_id_assign
    assign mgr_port_obi_req_o.a = mgr_port_a_in_sbr;
  end

  fifo_v3 #(
    .FALL_THROUGH( 1'b0                 ),
    .DATA_WIDTH  ( RequiredExtraIdWidth ),
    .DEPTH       ( NumMaxTrans          )
  ) i_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   ('0),
    .testmode_i,

    .full_o    ( fifo_full                                        ),
    .empty_o   (),
    .usage_o   (),
    .data_i    ( selected_id                                      ),
    .push_i    ( mgr_port_obi_req_o.req && mgr_port_obi_rsp_i.gnt ),

    .data_o    ( response_id                                      ),
    .pop_i     ( fifo_pop                                         )
  );

  if (MgrPortObiCfg.UseRReady) begin : gen_rready_connect
    assign mgr_port_obi_req_o.rready = sbr_port_obi_req_i[response_id].rready;
  end
  logic [NumSbrPorts-1:0] sbr_rsp_rvalid;
  sbr_port_r_chan_t [NumSbrPorts-1:0] sbr_rsp_r;
  always_comb begin : proc_sbr_rsp
    for (int i = 0; i < NumSbrPorts; i++) begin
      sbr_rsp_r[i] = '0;
      sbr_rsp_rvalid[i] = '0;
    end
    sbr_rsp_r[response_id] = mgr_port_obi_rsp_i.r;
    sbr_rsp_rvalid[response_id] = mgr_port_obi_rsp_i.rvalid;
  end

  for (genvar i = 0; i < NumSbrPorts; i++) begin : gen_sbr_rsp_assign
    assign sbr_ports_obi_rsp_o[i].r = sbr_rsp_r[i];
    assign sbr_ports_obi_rsp_o[i].rvalid = sbr_rsp_rvalid[i];
  end

  if (MgrPortObiCfg.UseRReady) begin : gen_fifo_pop
    assign fifo_pop = mgr_port_obi_rsp_i.rvalid && mgr_port_obi_req_o.rready;
  end else begin : gen_fifo_pop
    assign fifo_pop = mgr_port_obi_rsp_i.rvalid;
  end

endmodule
