// Copyright (c) 2012-2013 Ludvig Strigeus
// This program is GPL Licensed. See COPYING for the full license.
// 
// MiSTer port: Copyright (C) 2017,2018 Sorgelig

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [44:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output  [1:0] VGA_SL,

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S, // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)
	input         TAPE_IN,

	// SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..5 - USR1..USR4
	// Set USER_OUT to 1 to read from USER_IN.
	input   [5:0] USER_IN,
	output  [5:0] USER_OUT,

	input         OSD_STATUS
);

assign USER_OUT = '1;

assign AUDIO_S   = 1'b1;
assign AUDIO_L   = |mute_cnt ? 16'd0 : sample_signed[15:0];
assign AUDIO_R   = AUDIO_L;
assign AUDIO_MIX = 0;

assign LED_USER  = downloading | (loader_fail & led_blink) | (bk_state != S_IDLE) | (bk_pending & status[17]);
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign VIDEO_ARX = status[8] ? 8'd16 : 8'd4;
assign VIDEO_ARY = status[8] ? 8'd9  : 8'd3;

assign CLK_VIDEO = clk;

assign VGA_F1 = 0;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
//assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;


`define DEBUG_AUDIO

`include "build_id.v"
parameter CONF_STR1 = {
	"NES;;",
	"-;",
	"FS,NES;",
	"FS,FDS;",
};

parameter CONF_STR2 = {
	",BIN,Load FDS BIOS;",
	"-;",
	"OG,Disk Swap,Auto,FDS button;",	
	"O5,Invert mirroring,OFF,ON;",
	"-;",
};

parameter CONF_STR3 = {
	"6,Load Backup RAM;"
};

parameter CONF_STR4 = {
	"7,Save Backup RAM;",
	"OH,Autosave,No,Yes;",
	"-;",
	"O8,Aspect ratio,4:3,16:9;",
	"O13,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O4,Hide overscan,OFF,ON;",
	"OCF,Palette,Smooth,Unsat.,FCEUX,NES Classic,Composite,PC-10,PVM,Wavebeam,Real,Sony CXA,YUV,Greyscale,Rockman9,Nintendulator;",
	"-;",
	"O9,Swap joysticks,NO,YES;",
	"OIJ,Peripheral,Powerpad,Zapper(Mouse),Zapper(Joy1),Zapper(Joy2);",
	"OA,Multitap,Disabled,Enabled;",
`ifdef DEBUG_AUDIO
	"-;",
	"OUV,Audio Enable,Both,Internal,Cart Expansion,None;",
`endif
	"-;",
	"R0,Reset;",
	"J1,A,B,Select,Start,FDS,PP 1,PP 2,PP 3,PP 4,PP 5,PP 6,PP 7,PP 8,PP 9,PP 10,PP 11,PP 12,Mic,Trigger;",
	"V,v",`BUILD_DATE
};

wire [22:0] joyA,joyB,joyC,joyD;
wire [1:0] buttons;

wire [31:0] status;

wire arm_reset = status[0];
wire mirroring_osd = status[5];
wire hide_overscan = status[4];
wire [3:0] palette2_osd = status[15:12];
wire joy_swap = status[9];
wire fds_swap_invert = status[16];
`ifdef DEBUG_AUDIO
wire ext_audio = ~status[30];
wire int_audio = ~status[31];
`else
wire ext_audio = 1;
wire int_audio = 1;
`endif

// Remove DC offset and convert to signed
// At this CE rate, it also slightly lowers the bass to
// better imitate the real high pass of the system.
jt49_dcrm2 #(.sw(16)) dc_filter (
	.clk  (clk),
	.cen  (apu_ce & &filter_cnt),
	.rst  (reset_nes),
	.din  (sample),
	.dout (sample_signed)
);

wire apu_ce;
wire signed [15:0] sample_signed;

reg [20:0] mute_cnt = 21'h1FFFFF;

// Pause audio to avoid loud "POP"
always_ff @(posedge clk) begin
	if (reset_nes)
		mute_cnt <= 21'h1FFFFF;
	else if (|mute_cnt)
		mute_cnt <= mute_cnt - 1'b1;
end

// Filter CE impacts frequency response
reg [2:0] filter_cnt;
always_ff @(posedge clk) begin
	if (apu_ce)
		filter_cnt<= filter_cnt + 1'b1;
end



wire forced_scandoubler;
wire ps2_kbd_clk, ps2_kbd_data;

reg  [31:0] sd_lba;
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din;
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [7:0]  filetype;
wire [24:0] ioctl_addr;
reg         ioctl_wait;
wire [24:0] ps2_mouse;
wire [15:0] joy_analog0, joy_analog1;

hps_io #(.STRLEN(($size(CONF_STR1)>>3) + ($size(CONF_STR2)>>3) + ($size(CONF_STR3)>>3) + ($size(CONF_STR4)>>3) + 3)) hps_io
(
	.clk_sys(clk),
	.HPS_BUS(HPS_BUS),
	.conf_str({CONF_STR1,~bios_loaded ? "F" : "+",CONF_STR2,bk_ena ? "R" : "+",CONF_STR3,bk_ena ? "R" : "+",CONF_STR4}),

	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),

	.joystick_0(joyA),
	.joystick_1(joyB),
	.joystick_2(joyC),
	.joystick_3(joyD),
	.joystick_analog_0(joy_analog0),
	.joystick_analog_1(joy_analog1),

	.status(status),

	.ioctl_download(downloading),
	.ioctl_addr(ioctl_addr),
	.ioctl_wr(loader_clk),
	.ioctl_dout(file_input),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(filetype),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.ps2_kbd_led_use(0),
	.ps2_kbd_led_status(0),

	.ps2_mouse(ps2_mouse)
);


wire clock_locked;
wire clk85;
wire clk;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk85),
	.outclk_1(SDRAM_CLK),
	.outclk_2(clk),
	.locked(clock_locked)
);


// reset after download
reg [7:0] download_reset_cnt;
wire download_reset = download_reset_cnt != 0;
always @(posedge clk) begin
	if(downloading) download_reset_cnt <= 8'hFF;
	else if(!loader_busy && download_reset_cnt) download_reset_cnt <= download_reset_cnt - 1'd1;
end

// hold machine in reset until first download starts
reg init_reset_n = 0;
always @(posedge clk) if(downloading) init_reset_n <= 1;


wire  [8:0] cycle;
wire  [8:0] scanline;
wire [15:0] sample;
wire  [5:0] color;
wire        joypad_strobe;
wire  [1:0] joypad_clock;
wire [21:0] memory_addr;
wire        memory_read_cpu, memory_read_ppu;
wire        memory_write;
wire  [7:0] memory_din_cpu, memory_din_ppu;
wire  [7:0] memory_dout;
reg  [23:0] joypad_bits, joypad_bits2;
reg   [7:0] powerpad_d3, powerpad_d4;
reg   [1:0] last_joypad_clock;

wire [11:0] powerpad = joyA[20:9] | joyB[20:9] | joyC[20:9] | joyD[20:9];

wire [7:0] nes_joy_A = { joyA[0], joyA[1], joyA[2], joyA[3], joyA[7], joyA[6], joyA[5], joyA[4] };
wire [7:0] nes_joy_B = { joyB[0], joyB[1], joyB[2], joyB[3], joyB[7], joyB[6], joyB[5], joyB[4] };
wire [7:0] nes_joy_C = { joyC[0], joyC[1], joyC[2], joyC[3], joyC[7], joyC[6], joyC[5], joyC[4] };
wire [7:0] nes_joy_D = { joyD[0], joyD[1], joyD[2], joyD[3], joyD[7], joyD[6], joyD[5], joyD[4] };

wire mic_button = joyA[21] | joyB[21];
wire fds_btn = joyA[8] | joyB[8];
wire fds_swap = (fds_swap_invert ^ fds_btn);

reg [2:0] nes_ce;

reg [7:0] mic_cnt;

wire mic = (mic_cnt < 8'd215) && mic_button;
always @(posedge clk)
	mic_cnt <= (mic_cnt == 8'd250) ? 8'd0 : mic_cnt + 1'b1;

zapper zap (
	.clk(clk),
	.reset(reset_nes | ~lightgun_en),
	.mode(status[19]),
	.ps2_mouse(ps2_mouse),
	.analog(~status[18] ? joy_analog0 : joy_analog1),
	.analog_trigger(~status[18] ? joyA[22] : joyB[22]),
	.cycle(cycle),
	.scanline(scanline),
	.color(color),
	.reticule(reticule),
	.light(light),
	.trigger(trigger)
);

always @(posedge clk) begin
	if (reset_nes) begin
		joypad_bits <= 0;
		joypad_bits2 <= 0;
		powerpad_d3 <= 0;
		powerpad_d4 <= 0;
		last_joypad_clock <= 0;
	end else begin
		if (joypad_strobe) begin
			joypad_bits  <= {status[10] ? {8'h08, nes_joy_C} : 16'hFFFF, joy_swap ? nes_joy_B : nes_joy_A};
			joypad_bits2 <= {status[10] ? {8'h04, nes_joy_D} : 16'hFFFF, joy_swap ? nes_joy_A : nes_joy_B};
			powerpad_d4 <= {4'b0000, powerpad[7], powerpad[11], powerpad[2], powerpad[3]};
			powerpad_d3 <= {powerpad[6], powerpad[10], powerpad[9], powerpad[5], powerpad[8], powerpad[4], powerpad[0], powerpad[1]};
		end
		if (!joypad_clock[0] && last_joypad_clock[0]) begin
			joypad_bits <= {1'b0, joypad_bits[23:1]};
		end	
		if (!joypad_clock[1] && last_joypad_clock[1]) begin
			joypad_bits2 <= {1'b0, joypad_bits2[23:1]};
			powerpad_d4 <= {1'b0, powerpad_d4[7:1]};
			powerpad_d3 <= {1'b0, powerpad_d3[7:1]};
		end	
		last_joypad_clock <= joypad_clock;
	end
end

// Loader
wire [7:0] file_input;
wire [7:0] loader_input = (loader_busy && !downloading) ? bios_data : file_input;
wire       loader_clk;
wire [21:0] loader_addr;
wire [7:0] loader_write_data;
reg  [7:0] old_filetype;
wire loader_reset = !download_reset || ((old_filetype != filetype) && |filetype); //loader_conf[0];
wire loader_write;
wire [31:0] loader_flags;
reg  [31:0] mapper_flags;
wire loader_busy, loader_done, loader_fail;
wire bios_download;

GameLoader loader
(
	clk, loader_reset, downloading, filetype,
	loader_input, loader_clk, mirroring_osd,
	loader_addr, loader_write_data, loader_write, bios_download,
	loader_flags, loader_busy, loader_done, loader_fail
);

always @(posedge clk) begin
	if (loader_done) mapper_flags <= loader_flags;
	old_filetype <= filetype;
end

reg led_blink;
always @(posedge clk) begin
	int cnt = 0;
	cnt <= cnt + 1;
	if(cnt == 10000000) begin
		cnt <= 0;
		led_blink <= ~led_blink;
	end;
end
 
wire reset_nes = ~init_reset_n || buttons[1] || arm_reset || download_reset || loader_fail || bk_loading || bk_loading_req;

wire [15:0] bram_addr;
wire [7:0] bram_din;
wire [7:0] bram_dout;
wire bram_write;
wire bram_override;
wire trigger;
wire light;

wire [1:0] diskside_req;
reg [1:0] diskside;
//reg fds_swap;

wire lightgun_en = |status[19:18];

NES nes (
	.clk             (clk),
	.reset           (reset_nes),
	.nes_div         (nes_ce),
	.mapper_flags    (downloading ? 32'd0 : mapper_flags),
	// Audio
	.sample          (sample),
	.audio_channels  (5'b11111),
	.int_audio       (int_audio),
	.ext_audio       (ext_audio),
	.apu_ce          (apu_ce),
	// Video
	.color           (color),
	.emphasis        (emphasis),
	.cycle           (cycle),
	.scanline        (scanline),
	// User Input
	.joypad_strobe   (joypad_strobe),
	.joypad_clock    (joypad_clock),
	.joypad_data     ({lightgun_en ? trigger : powerpad_d4[0],lightgun_en ? light : powerpad_d3[0],joypad_bits2[0],joypad_bits[0]}),
	.mic             (mic),
	.diskside_req    (diskside_req),
	.diskside        (diskside),
	.fds_busy        (fds_busy),
	.fds_swap        (fds_swap),
	// Memory transactions
	.memory_addr     (memory_addr),
	.memory_read_cpu (memory_read_cpu),
	.memory_din_cpu  (memory_din_cpu),
	.memory_read_ppu (memory_read_ppu),
	.memory_din_ppu  (memory_din_ppu),
	.memory_write    (memory_write),
	.memory_dout     (memory_dout),
	.bram_addr       (bram_addr),
	.bram_din        (bram_din),
	.bram_dout       (bram_dout),
	.bram_write      (bram_write),
	.bram_override   (bram_override),
	.save_written    (save_written)
);

wire [2:0] emphasis;

assign SDRAM_CKE         = 1'b1;

wire [7:0] xor_data;
wire [7:0] bios_data;
wire bios_write = (loader_write && bios_download && ~bios_loaded);
reg bios_loaded = 0; // Only load bios once
reg last_bios_download = 0;

always @(posedge clk) begin
	last_bios_download <= bios_download;
	if(last_bios_download && ~bios_download) begin
		bios_loaded = 1;
	end
end

dpram #("fdspatch.mif", 13) biospatch
(
	.clock_a(clk),
	.address_a(ioctl_addr[12:0]),
	.wren_a(bios_write),
	.data_a(bios_data ^ loader_write_data),
	.q_a(xor_data),
	
	.clock_b(clk),
	.address_b(loader_addr[12:0]),
	.q_b(bios_data)
);

// loader_write -> clock when data available
reg loader_write_mem;
reg [7:0] loader_write_data_mem;
reg [21:0] loader_addr_mem;

reg loader_write_triggered;

always @(posedge clk) begin
	if(loader_write) begin
		loader_write_triggered <= 1'b1;
		loader_addr_mem <= loader_addr;
		loader_write_data_mem <= bios_download ? loader_write_data ^ xor_data : loader_write_data;
		ioctl_wait <= 1;
	end

	if(nes_ce == 3 || fds_wr) begin
		loader_write_mem <= loader_write_triggered;
		if(loader_write_triggered || fds_wr) begin
			loader_write_triggered <= 1'b0;
			if (fds_wr || (~bios_download && loader_addr_mem[18])) ddr_wr <= ~ddr_wr;
		end else if(ioctl_wait && (ddr_wr == ddr_wrack)) begin
			ioctl_wait <= 0;
		end
	end
end

sdram sdram
(
	// interface to the MT48LC16M16 chip
	.sd_data        ( SDRAM_DQ                 ),
	.sd_addr        ( SDRAM_A                  ),
	.sd_dqm         ( {SDRAM_DQMH, SDRAM_DQML} ),
	.sd_cs          ( SDRAM_nCS                ),
	.sd_ba          ( SDRAM_BA                 ),
	.sd_we          ( SDRAM_nWE                ),
	.sd_ras         ( SDRAM_nRAS               ),
	.sd_cas         ( SDRAM_nCAS               ),

	// system interface
	.clk            ( clk85                    ),
	.clkref         ( nes_ce[1]                ),
	.init           ( !clock_locked            ),

	// cpu/chipset interface
	.addr           ( (downloading || loader_busy) ? {3'b000, loader_addr_mem} : {3'b000, memory_addr} ),
	
	.we             ( memory_write || loader_write_mem	),
	.din            ( (downloading || loader_busy) ? loader_write_data_mem : memory_dout ),
	
	.oeA            ( memory_read_cpu ),
	.doutA          ( memory_din_cpu  ),
	
	.oeB            ( memory_read_ppu ),
	.doutB          ( memory_din_ppu  ),

	.bk_clk         ( clk ),
	.bk_addr        ( bk_busy ? {fds_addr[15:9],sd_buff_addr} : fds_addr[15:0] ),
	.bk_dout        ( sd_buff_din ),
	.bk_din         ( bk_busy ? sd_buff_dout : fds_data ),
	.bk_we          ( bk_busy ? sd_buff_wr & sd_ack : bram_we ),
	.bko_addr       ( bram_addr ),
	.bko_dout       ( bram_din ),
	.bko_din        ( bram_dout ),
	.bko_we         ( bram_write ),
	.bk_override    ( bram_override )
);

reg bk_pending;
wire save_written;
always @(posedge clk) begin
	if ((mapper_flags[25] || fds) && ~OSD_STATUS && save_written)
		bk_pending <= 1'b1;
	else if (bk_state)
		bk_pending <= 1'b0;
end

///////////////////////////////////////////////////

wire [21:0] fdsddr_addr;
wire [7:0] fds_data;
wire fds_rd, fds_rdy;
assign DDRAM_CLK = clk85;

ddram ddram
(
	.*,

   .wraddr(bk_ena ? {fdsddr_addr[17:0], 1'b0} : {loader_addr_mem[17:0], 1'b0}),
   .din(bk_ena ? {sd_buff_din, sd_buff_din} : {loader_write_data, loader_write_data}), //({ioctl_data[7:0],ioctl_data[15:8]}),
   .we_req(ddr_wr),
   .we_ack(ddr_wrack),

   .rdaddr({fdsddr_addr[17:0], 1'b0}),
   .dout(fds_data),
   .rd_req(fds_rd),
   .rd_rdy(fds_rdy)
);

reg  ddr_wr;
wire ddr_wrack;

wire downloading;

wire [2:0] scale = status[3:1];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;
assign VGA_SL = sl[1:0];

wire reticule;

video video
(
	.*,
	.clk(clk),
	.count_v(scanline),
	.count_h(cycle),
	.forced_scandoubler(forced_scandoubler),
	.scale(scale),
	.hide_overscan(hide_overscan),
	.palette(palette2_osd),
	.emphasis(emphasis),
	.reticule(reticule),

	.ce_pix(CE_PIXEL)
);


/////////////////////////  STATE SAVE/LOAD  /////////////////////////////

reg bk_ena = 0;
reg old_downloading = 0;
reg [1:0] last_diskside = 2'd3;
always @(posedge clk) begin
	old_downloading <= downloading;
	if(~old_downloading & downloading) bk_ena <= 0;
	
	//Save file always mounted in the end of downloading state.
	if(downloading && img_mounted && !img_readonly) bk_ena <= 1;
	if(~bk_ena && loader_write_triggered) last_diskside <= loader_addr_mem[17:16];
end

wire bk_load    = status[6];
wire bk_save    = status[7] | (bk_pending & OSD_STATUS && status[17]);
reg  bk_loading = 0;
reg  bk_loading_req = 0;
reg  bk_request = 0;
wire bk_busy = (bk_state == S_COPY);
reg  full_loading = 0;
reg  full_loading_req = 0;
reg  bram_init = 0;
reg  bram_we = 0;
reg  fds_wr;
reg  bk_first;
reg  fds_busy;
reg  old_fds_btn;
reg [1:0] diskside_btn;
wire fds = (mapper_flags[7:0] == 8'h14);
reg [17:0] fds_addr;
// 65500 size; 512 sector size; After first size, beginning of side is in previous sector
assign fdsddr_addr = {4'h0, (diskside==2'd0) ? fds_addr : fds_addr - 16'h0200};
assign sd_lba = {23'h0, (diskside==2'd0) ? fds_addr[17:9] : fds_addr[17:9] - 9'h1};
wire [17:0] img_last = (|img_size) ? img_size - 18'd1 : 0;
wire [1:0] diskside_req_use = fds_swap_invert ? diskside_btn : diskside_req;
wire [1:0] next_diskside = (last_diskside == diskside) ? 2'd0 : diskside + 2'd1;
wire [1:0] next_btn_diskside = (last_diskside == diskside_btn) ? 2'd0 : diskside_btn + 2'd1;

// This state machine needs to handle the following:
// - For non FDS games, S_COPY reads the save file into BRAM on ROM load and when requested by OSD.
// - S_COPY also writes the contents of BRAM to the save when requested by OSD (or autosave).
// - For FDS games, after the FDS has been loaded to DDR, one diskside is copied to BRAM (S_COPYDDR)
// - After this, if a save exists, it is loaded one diskside at a time into BRAM (S_COPY).
// - Each diskside in BRAM then overwrites DDR (S_DDRCOPY).  This is done for each diskside.
// - When requested by OSD (including autosave), the current BRAM contents are saved to disk (S_COPY).
// - Whenever the diskside changes, first the current BRAM is copied to disk (S_COPY).
// - Then the current BRAM is copied to DDR (S_DDRCOPY).
// - Then the next diskside is loaded into BRAM from DDR (S_COPYDDR).
typedef enum bit [1:0] { S_IDLE, S_COPY, S_DDRCOPY, S_COPYDDR } mystate;
mystate bk_state = S_IDLE;

always @(posedge clk) begin
	reg old_load = 0, old_save = 0, old_ack;
	
	old_load <= bk_load & bk_ena;
	old_save <= bk_save & bk_ena;
	old_ack  <= sd_ack;
	fds_busy <= (bk_state != S_IDLE) || bk_request;
	old_fds_btn <= fds_btn;
	
	if(~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;
	if(~old_fds_btn & fds_btn) diskside_btn <= next_btn_diskside;
	if (downloading) begin
		diskside <= 2'd0;
		bram_init <= ~fds;
		bk_state <= S_IDLE;
		bk_request <= 0;
		full_loading <= 0;
		full_loading_req <= 0;
		bk_loading_req <= 0;
		diskside_btn <= 2'd0;
	end else begin
		if((~old_load & bk_load) | (~old_save & bk_save)) begin
			bk_loading_req <= bk_load;
			bk_request <= 1;
			full_loading_req <= 0;
		end
		if(old_downloading & ~downloading & |img_size & bk_ena) begin
			bk_loading_req <= 1;
			bk_request <= 1;
			full_loading_req <= 1;
		end
		if(bk_state == S_IDLE) begin
			if(!bram_init && ~loader_busy && ~downloading) begin
				bk_loading <= 1;
				full_loading <= 0;
				bk_state <= S_COPYDDR;
				fds_addr <= {2'd0, 16'h0};
				diskside <= 2'd0;
				bk_first <= 1;
			end else if(bram_init && (diskside_req_use != diskside) && ~downloading && ~bk_request && fds) begin
				bk_loading_req <= 0;
				bk_request <= 1;
				full_loading_req <= 0;
				fds_addr <= {diskside, 16'h0};
			end
			if (bram_init && bk_request && ~downloading && !loader_busy) begin
				bk_state <= S_COPY;
				fds_addr <= full_loading_req ? 18'h0 : {diskside, 16'h0};
				diskside <= full_loading_req ? 2'd0 : diskside;
				full_loading <= full_loading_req;
				full_loading_req <= 0;
				bk_loading <= full_loading_req || bk_loading_req;
				bk_loading_req <= 0;
				bk_first <= 1;
			end
		end else if(bk_state == S_COPY) begin
			if (bk_first) begin
				bk_request <= 0;  //one cycle pause
				sd_rd <=  bk_loading;
				sd_wr <= ~bk_loading;
				bk_first <= 0;
			end else if(old_ack & ~sd_ack) begin
				if((&fds_addr[14:9] && (fds_addr[15] == fds)) || (bk_loading && (fds_addr[17:9] == img_last[17:9]))) begin
					fds_addr <= {diskside, 16'h0};
					bk_state <= fds ? S_DDRCOPY : S_IDLE;
					bk_loading <= fds ? bk_loading : 1'd0;
					bram_init <= 1;
					bk_first <= 1;
				end else begin
					fds_addr[17:9] <= fds_addr[17:9] + 1'd1;
					sd_rd  <=  bk_loading;
					sd_wr  <= ~bk_loading;
				end
			end
		end else if(bk_state == S_DDRCOPY) begin
			fds_wr <= 0;
			if (bk_first) begin
				bk_first <= 0;
				fds_wr <= 1;
			end else if (~fds_wr && (ddr_wr == ddr_wrack)) begin
				if(&fds_addr[15:0]) begin
					full_loading <= full_loading && (img_last[17:16] != diskside);
					bk_loading <= bk_loading && ~(full_loading && (img_last[17:16] == diskside));
					bk_state <= full_loading ? (img_last[17:16] != diskside) ? S_COPY : S_IDLE : S_COPYDDR;
					diskside <= (full_loading && (img_last[17:16] == diskside)) ? diskside : next_diskside;
					fds_addr <= {next_diskside, 16'h0};
					bk_first <= 1;
				end else begin
					fds_addr <= fds_addr + 1'd1;
					fds_wr <= 1;
				end
			end
		end else begin // if(bk_state == S_COPYDDR) begin
			bram_we <= 0;
			if (bk_first) begin
				bk_first <= 0;
				fds_rd <= 1;
			end else if (fds_rdy && ~fds_rd) begin
				if(&fds_addr[15:0]) begin
					bk_loading <= 0;
					bk_state <= S_IDLE;
					fds_addr <= {diskside, 16'h0};
					bram_init <= 1;
				end else begin
					fds_addr <= fds_addr + 1'd1;
					fds_rd <= 1;
				end
			end else begin
				fds_rd <= 0;
				bram_we <= 1;
			end
		end
	end
end

endmodule


/////////////////////////////////////////////////////////////////////////

// Module reads bytes and writes to proper address in ram.
// Done is asserted when the whole game is loaded.
// This parses iNES headers too.
module GameLoader
(
	input         clk,
	input         reset,
	input         downloading,
	input   [7:0] filetype,
	input   [7:0] indata,
	input         indata_clk,
	input         invert_mirroring,
	output reg [21:0] mem_addr,
	output [7:0]  mem_data,
	output        mem_write,
	output reg    bios_download,
	output [31:0] mapper_flags,
	output reg    busy,
	output reg    done,
	output reg    error
);

reg [7:0] prgsize;
reg [3:0] ctr;
reg [7:0] ines[0:15]; // 16 bytes of iNES header
reg [21:0] bytes_left;
  
wire [7:0] prgrom = ines[4];	// Number of 16384 byte program ROM pages
wire [7:0] chrrom = ines[5];	// Number of 8192 byte character ROM pages (0 indicates CHR RAM)
wire has_chr_ram = (chrrom == 0);
assign mem_data = (state == S_CLEARRAM || (~copybios && state == S_COPYBIOS)) ? 8'h00 : indata;
assign mem_write = (((bytes_left != 0) && (state == S_LOADPRG || state == S_LOADCHR)
                    || (downloading && (state == S_LOADHEADER || state == S_LOADFDS))) && indata_clk)
						 || ((bytes_left != 0) && ((state == S_CLEARRAM) || (state == S_COPYBIOS)) && clearclk == 4'h2);
  
wire [2:0] prg_size = prgrom <= 1  ? 3'd0 :		// 16KB
                      prgrom <= 2  ? 3'd1 : 		// 32KB
                      prgrom <= 4  ? 3'd2 : 		// 64KB
                      prgrom <= 8  ? 3'd3 : 		// 128KB
                      prgrom <= 16 ? 3'd4 : 		// 256KB
                      prgrom <= 32 ? 3'd5 : 		// 512KB
                      prgrom <= 64 ? 3'd6 : 3'd7;// 1MB/2MB
                        
wire [2:0] chr_size = chrrom <= 1  ? 3'd0 : 		// 8KB
                      chrrom <= 2  ? 3'd1 : 		// 16KB
                      chrrom <= 4  ? 3'd2 : 		// 32KB
                      chrrom <= 8  ? 3'd3 : 		// 64KB
                      chrrom <= 16 ? 3'd4 : 		// 128KB
                      chrrom <= 32 ? 3'd5 : 		// 256KB
                      chrrom <= 64 ? 3'd6 : 3'd7;// 512KB/1MB
  
// detect iNES2.0 compliant header
wire is_nes20 = (ines[7][3:2] == 2'b10);
// differentiate dirty iNES1.0 headers from proper iNES2.0 ones
wire is_dirty = !is_nes20 && ((ines[9][7:1] != 0)
								  || (ines[10] != 0)
								  || (ines[11] != 0)
								  || (ines[12] != 0)
								  || (ines[13] != 0)
								  || (ines[14] != 0)
								  || (ines[15] != 0));

// Read the mapper number
wire [7:0] mapper = {is_dirty ? 4'b0000 : ines[7][7:4], ines[6][7:4]};
wire [7:0] ines2mapper = {is_nes20 ? ines[8] : 8'h00};

wire has_saves = ines[6][1];

// ines[6][0] is mirroring
// ines[6][3] is 4 screen mode
// ines[8][7:4] is NES 2.0 submapper
assign mapper_flags = {6'b0, has_saves, ines2mapper, ines[6][3], has_chr_ram, ines[6][0] ^ invert_mirroring, chr_size, prg_size, mapper};

reg [3:0] clearclk; //Wait for SDRAM
reg copybios;

typedef enum bit [2:0] { S_LOADHEADER, S_LOADPRG, S_LOADCHR, S_LOADFDS, S_ERROR, S_CLEARRAM, S_COPYBIOS, S_DONE } mystate;
mystate state;

wire type_bios = (filetype == 0 || filetype == 3); //*.BIOS or boot.rom or boot0.rom
//wire type_nes = (filetype == 1 || filetype==8'h40); //*.NES or boot1.rom  //default
wire type_fds = (filetype == 2 || filetype==8'h80); //*.FDS or boot2.rom

always @(posedge clk) begin
	if (reset) begin
		state <= S_LOADHEADER;
		busy <= 0;
		done <= 0;
		ctr <= 0;
		mem_addr <= type_fds ? 22'b00_0100_0000_0000_0001_0000 : 22'b00_0000_0000_0000_0000_0000;  // Address for FDS : BIOS/PRG
		bios_download <= 0;
		copybios <= 0;
	end else begin
		case(state)
		// Read 16 bytes of ines header
		S_LOADHEADER:
			if (indata_clk) begin
			  error <= 0;
			  ctr <= ctr + 1'd1;
			  mem_addr <= mem_addr + 1'd1;
			  ines[ctr] <= indata;
			  bytes_left <= {prgrom, 14'b0};
			  if (ctr == 4'b1111) begin
				 // Check the 'NES' header. Also, we don't support trainers.
				 busy <= 1;
				 if ((ines[0] == 8'h4E) && (ines[1] == 8'h45) && (ines[2] == 8'h53) && (ines[3] == 8'h1A) && !ines[6][2]) begin
					mem_addr <= 0;  // Address for PRG
					state <= S_LOADPRG;
				 //FDS
				 end else if ((ines[0] == 8'h46) && (ines[1] == 8'h44) && (ines[2] == 8'h53) && (ines[3] == 8'h1A)) begin
					mem_addr <= 22'b00_0100_0000_0000_0001_0000;  // Address for FDS skip Header
					state <= S_LOADFDS;
					bytes_left <= 21'b1;
				 end else if (type_bios) begin // Bios
					state <= S_LOADFDS;
					mem_addr <= 22'b00_0000_0000_0000_0001_0000;  // Address for BIOS skip Header
					bytes_left <= 21'b1;
					bios_download <= 1;
				 end else if(type_fds) begin // FDS
					state <= S_LOADFDS;
					mem_addr <= 22'b00_0100_0000_0000_0010_0000;  // Address for FDS no Header
					bytes_left <= 21'b1;
				 end else begin
					state <= S_ERROR;
				 end
			  end
			end
		S_LOADPRG, S_LOADCHR: begin // Read the next |bytes_left| bytes into |mem_addr|
			 if (bytes_left != 0) begin
				if (indata_clk) begin
				  bytes_left <= bytes_left - 1'd1;
				  mem_addr <= mem_addr + 1'd1;
				end
			 end else if (state == S_LOADPRG) begin
				state <= S_LOADCHR;
				mem_addr <= 22'b10_0000_0000_0000_0000_0000; // Address for CHR
				bytes_left <= {1'b0, chrrom, 13'b0};
			 end else if (state == S_LOADCHR) begin
				done <= 1;
				busy <= 0;
			 end
			end
		S_ERROR: begin
				done <= 1;
				error <= 1;
				busy <= 0;
			end
		S_LOADFDS: begin // Read the next |bytes_left| bytes into |mem_addr|
			 if (downloading) begin
				if (indata_clk) begin
				  mem_addr <= mem_addr + 1'd1;
				end
			 end else begin
//				mem_addr <= 22'b11_1000_0000_0000_0000_0000;
//				bytes_left <= 21'h800;
				mem_addr <= 22'b11_1000_0000_0001_0000_0010; // FDS - Clear these two RAM addresses to restart BIOS
				bytes_left <= 21'h2;
				ines[4] <= 8'hFF;//no masking
				ines[5] <= 8'h00;//0x2000
				ines[6] <= 8'h40;
				ines[7] <= 8'h10;
				ines[8] <= 8'h00;
				ines[9] <= 8'h00;
				ines[10] <= 8'h00;
				ines[11] <= 8'h00;
				ines[12] <= 8'h00;
				ines[13] <= 8'h00;
				ines[14] <= 8'h00;
				ines[15] <= 8'h00;
				state <= S_CLEARRAM;
				clearclk <= 4'h0;
				copybios <= (|filetype); // Don't copybios for bootrom0
			 end
			end
		S_CLEARRAM: begin // Read the next |bytes_left| bytes into |mem_addr|
			 clearclk <= clearclk + 4'h1;
			 if (bytes_left != 21'h0) begin
				if (clearclk == 4'hF) begin
					bytes_left <= bytes_left - 1'd1;
					mem_addr <= mem_addr + 1'd1;
				end
			 end else begin
				mem_addr <= 22'b00_0000_0000_0000_0000_0000;
				bytes_left <= 21'h2000;
				state <= S_COPYBIOS;
				clearclk <= 4'h0;
			 end
			end
		S_COPYBIOS: begin // Read the next |bytes_left| bytes into |mem_addr|
			 clearclk <= clearclk + 4'h1;
			 if (bytes_left != 21'h0) begin
				if (clearclk == 4'hF) begin
					bytes_left <= bytes_left - 1'd1;
					mem_addr <= mem_addr + 1'd1;
				end
			 end else begin
				state <= S_DONE;
			 end
			end
		S_DONE: begin // Read the next |bytes_left| bytes into |mem_addr|
			 done <= 1;
			 busy <= 0;
			 bios_download <= 0;
			end
		endcase
	end
end
endmodule
