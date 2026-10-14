-- Full-chip uoe testbench: the whole design, driven the way the board will.
--
-- The block-level testbenches each prove one hop. This one proves they are
-- connected in the right order and tests the three things that exist only at
-- the top level:
--
--   * the endianness converters on mac_rx / mac_tx. Everything inside is
--     MSB-first; the MAC ports are byte-reversed. The vectors are swapped in
--     Python, NOT by instantiating the RTL's own converter here -- otherwise a
--     bug in it would cancel out between input and output.
--
--   * circular_buffer_filter. It is the only consumer of the MAC's error flag,
--     so the "MAC error flag set" case checks that flag end to end.
--
--   * arp_handler and axis_priority_handler. ARP replies and TX frames share
--     mac_tx, and nothing specifies how they interleave -- so mac_tx is
--     compared per EtherType (reference_model/split_mac_tx.py), which keeps
--     every property that IS defined and tests no scheduling that is not.
--
-- Two independent streams run at once: frames into mac_rx and payloads into
-- udp_tx. That concurrency is the point -- it is the only place ARP arbitration
-- against live TX traffic happens.
--
-- xsim exits 0 even on a failed assertion, so the pass/fail signal is the
-- printed "protocol errors=N" line. Keep the wording; run_uoe_test.sh parses it.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity uoe_tb_full is
    generic (
        STIMULUS_FILE  : string  := "stimulus_uoe_tb_mac_rx.txt";
        STIMULUS_TX    : string  := "stimulus_uoe_tb_udp_tx.txt";
        AXIS_FILE      : string  := "axis_uoe_tb_udp_rx.txt";
        AXIS_TX_FILE   : string  := "axis_uoe_tb_mac_tx.txt";
        SIDEBAND_FILE  : string  := "sideband_uoe_tb.txt";
        -- backpressure from the MAC on the transmit side. 100 = never stall.
        READY_PERCENT  : integer := 100;
        -- The XXV MAC's receive stream has no tready: it delivers whether the
        -- design is ready or not. Driving mac_rx politely is optimistic, so
        -- this defaults to modelling the real thing. Set false to drive mac_rx
        -- with a normal tready handshake instead.
        MAC_IGNORES_TREADY : boolean := true
    );
end uoe_tb_full;


architecture sim of uoe_tb_full is

    constant clk_period : time := 10 ns;

    -- must match reference_model/gen_uoe.py
    constant CONF_MAC_C     : std_logic_vector(47 downto 0) := x"DECAFBAD0101";
    constant CONF_IP_C      : std_logic_vector(31 downto 0) := x"C0A80101";
    constant CONF_PORT_C    : std_logic_vector(15 downto 0) := x"04D2";
    constant DST_MAC_C      : std_logic_vector(47 downto 0) := x"CAFEF00D0202";
    constant DST_IP_C       : std_logic_vector(31 downto 0) := x"C0A80164";
    constant DST_PORT_C     : std_logic_vector(15 downto 0) := x"1234";
    constant DST_MAC_B      : std_logic_vector(47 downto 0) := x"0A0B0C0D0E0F";
    constant DST_IP_B       : std_logic_vector(31 downto 0) := x"C0A801FE";
    constant DST_PORT_B     : std_logic_vector(15 downto 0) := x"5678";

    -- Generous; uoe stretches any reset to 64 clocks internally, and
    -- uoe_reset_tb checks that separately.
    constant RESET_CLOCKS : natural := 32;

    -- The design is store-and-forward in several places at once, so the tail
    -- is long: a TX frame can be queued behind an ARP reply behind a stalled
    -- sink. Watch the output rather than counting a fixed number of clocks.
    constant IDLE_TO_FINISH : natural := 2000;
    constant TIMEOUT        : time    := 3 ms;

    signal clk, rstn : std_logic := '0';

    -- mac_rx: driven by axis_driver, byte-swapped vectors
    signal mac_rx      : axis_beat_t := AXIS_IDLE;
    signal mac_rx_tready : std_logic;

    -- udp_tx: driven by a second axis_driver
    signal udp_tx      : axis_beat_t := AXIS_IDLE;
    signal udp_tx_tready : std_logic;

    -- udp_rx: the user side of the receive path. No tready in the rx path.
    signal udp_rx : axis_beat_t := AXIS_IDLE;

    -- mac_tx: the wire. axis_stall provides the MAC's backpressure.
    signal mac_tx        : axis_beat_t := AXIS_IDLE;
    signal mac_tx_tready : std_logic;

    signal udp_rx_src_mac  : std_logic_vector(47 downto 0);
    signal udp_rx_src_ip   : std_logic_vector(31 downto 0);
    signal udp_rx_src_port : std_logic_vector(15 downto 0);
    signal udp_rx_dst_port : std_logic_vector(15 downto 0);


    -- per-packet TX destination: B for every third case, A otherwise
    signal dst_is_b   : boolean;
    signal tx_dst_mac : std_logic_vector(47 downto 0);
    signal tx_dst_ip  : std_logic_vector(31 downto 0);
    signal tx_dst_port: std_logic_vector(15 downto 0);

    -- which case each driver is playing, for the waveform
    signal rx_case_index, tx_case_index : natural;
    signal rx_case_name,  tx_case_name  : case_name_t;

    signal rx_drv_done, tx_drv_done : std_logic := '0';
    signal close_files              : std_logic := '0';
    signal timed_out                : std_logic := '0';

    signal udp_rx_errors, mac_tx_errors : natural;
    signal arp_fifo_errors              : natural := 0;
    signal udp_rx_beats, udp_rx_packets : natural;
    signal mac_tx_beats, mac_tx_packets : natural;
    signal sb_samples                   : natural;

    -- sideband is sampled at start of packet, not at tlast: dst_port is a
    -- routing signal and must be valid on the first beat. src_mac and src_ip
    -- were latched further upstream, so they are settled by then too.
    signal sop        : std_logic := '1';
    signal sb_trigger : std_logic;
    signal sb_value   : std_logic_vector(111 downto 0);

begin

    clk  <= not(clk) after clk_period/2;
    rstn <= '0', '1' after RESET_CLOCKS * clk_period;

    ------------------------------------------------------------------
    -- stimulus
    ------------------------------------------------------------------
    rx_driver: entity work.axis_driver
        generic map (STIMULUS_FILE => STIMULUS_FILE,
                     IGNORE_TREADY => MAC_IGNORES_TREADY,
                     -- Must clear uoe's reset STRETCHER, not just rstn. The pin
                     -- releases after RESET_CLOCKS, but rstn_sync is held ~64
                     -- clocks longer, and a source that ignores tready loses
                     -- everything it sends into that window.
                     START_DELAY   => 128)
        port map (
            clk => clk, rstn => rstn,
            axis => mac_rx, tready => mac_rx_tready,
            case_index => rx_case_index, case_name => rx_case_name,
            done => rx_drv_done);

    tx_driver: entity work.axis_driver
        generic map (STIMULUS_FILE => STIMULUS_TX)
        port map (
            clk => clk, rstn => rstn,
            axis => udp_tx, tready => udp_tx_tready,
            case_index => tx_case_index, case_name => tx_case_name,
            done => tx_drv_done);

    -- The destination follows the TX case being driven: A A B A A B ..., must
    -- match tx_dst() in gen_uoe.py. case_index moves when the driver reaches
    -- the next case, before any idle gap ahead of its first beat, so
    -- conf_tx_dst_* changes as soon as the previous packet's tlast is
    -- accepted -- the earliest the contract allows, and while earlier
    -- packets are still inside the TX path.
    dst_is_b    <= tx_case_index mod 3 = 0;
    tx_dst_mac  <= DST_MAC_B  when dst_is_b else DST_MAC_C;
    tx_dst_ip   <= DST_IP_B   when dst_is_b else DST_IP_C;
    tx_dst_port <= DST_PORT_B when dst_is_b else DST_PORT_C;

    mac_sink: entity work.axis_stall
        generic map (READY_PERCENT => READY_PERCENT, SEED1 => 24680, SEED2 => 1357)
        port map (clk => clk, rstn => rstn, tready => mac_tx_tready);

    ------------------------------------------------------------------
    -- capture
    ------------------------------------------------------------------
    udp_rx_mon: entity work.axis_monitor
        generic map (AXIS_FILE => AXIS_FILE)
        port map (
            clk => clk, axis => udp_rx, tready => '1',
            close_file => close_files,
            beats => udp_rx_beats, packets => udp_rx_packets);

    mac_tx_mon: entity work.axis_monitor
        generic map (AXIS_FILE => AXIS_TX_FILE)
        port map (
            clk => clk, axis => mac_tx, tready => mac_tx_tready,
            close_file => close_files,
            beats => mac_tx_beats, packets => mac_tx_packets);

    -- udp_rx has no tready, so its stability rules are vacuous -- but the
    -- tlast/tkeep/X checks are not, and mac_tx is fully handshaked.
    -- A jumbo payload is 1120 beats, so the default 512-beat tlast watchdog
    -- fires on a perfectly good packet. 2048 covers the largest frame the RX
    -- path can buffer.
    udp_rx_chk: entity work.axis_checker
        generic map (NAME => "uoe.udp_rx", MAX_PACKET_BEATS => 2048)
        port map (clk => clk, rstn => rstn, axis => udp_rx, tready => '1',
                  errors => udp_rx_errors);

    mac_tx_chk: entity work.axis_checker
        -- mac_tx is downstream of tx_endi, so its tkeep is byte-reversed: a
        -- partial final beat reads 0F, not F0.
        generic map (NAME => "uoe.mac_tx", CHECK_TUSER_ON_TLAST => false,
                     KEEP_LSB_FIRST => true, MAX_PACKET_BEATS => 2048)
        port map (clk => clk, rstn => rstn, axis => mac_tx, tready => mac_tx_tready,
                  errors => mac_tx_errors);

    sop_proc: process(clk)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                sop <= '1';
            elsif(udp_rx.tvalid = '1') then
                sop <= udp_rx.tlast;
            end if;
        end if;
    end process;

    sb_trigger <= udp_rx.tvalid and sop;
    sb_value   <= udp_rx_src_mac & udp_rx_src_ip & udp_rx_src_port & udp_rx_dst_port;

    -- arp_fifo must never refuse a write: arp_handler stops on prog_full, and
    -- that margin (FIFO_DEPTH, PROG_FULL_THRESH, an 8-beat reply) is what
    -- keeps it from ever being full. uoe.vhd leaves the FIFO's s_axis_tready
    -- on out_arp_fifo_wready, read by nothing, so it can be checked here.
    arp_fifo_chk: process(clk)
        alias arp_tvalid is <<signal .uoe_tb_full.DUT.out_arp_handler_tvalid : std_logic>>;
        alias arp_wready is <<signal .uoe_tb_full.DUT.out_arp_fifo_wready : std_logic>>;
    begin
        if(rising_edge(clk)) then
            if(arp_tvalid = '1' and arp_wready /= '1') then
                report "uoe.arp_fifo: arp_handler wrote while the FIFO was not ready"
                    severity error;
                arp_fifo_errors <= arp_fifo_errors + 1;
            end if;
        end if;
    end process;

    sb_mon: entity work.sideband_monitor
        generic map (SIDEBAND_FILE => SIDEBAND_FILE, WIDTH => 112)
        port map (clk => clk, trigger => sb_trigger, value => sb_value,
                  close_file => close_files, samples => sb_samples);

    ------------------------------------------------------------------
    -- watchdog
    ------------------------------------------------------------------
    watchdog: process
    begin
        wait for TIMEOUT;
        timed_out <= '1';
        wait;
    end process;

    ------------------------------------------------------------------
    -- test control
    ------------------------------------------------------------------
    control_proc: process
        variable idle : natural := 0;
    begin
        -- both streams have to finish; they are independent and either may
        -- outlast the other depending on backpressure
        wait until (rx_drv_done = '1' and tx_drv_done = '1') or timed_out = '1';

        loop
            wait until rising_edge(clk);
            if((udp_rx.tvalid = '1') or
               (mac_tx.tvalid = '1' and mac_tx_tready = '1')) then
                idle := 0;
            else
                idle := idle + 1;
            end if;
            exit when idle >= IDLE_TO_FINISH or timed_out = '1';
        end loop;

        -- Close before any assertion can abort, so a failure still leaves
        -- complete files to diff. Two edges: the monitors close on the first,
        -- and process order within one delta is undefined.
        close_files <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "udp_rx beats=" & integer'image(udp_rx_beats) &
               " packets=" & integer'image(udp_rx_packets) &
               " | mac_tx beats=" & integer'image(mac_tx_beats) &
               " packets=" & integer'image(mac_tx_packets) &
               " sideband=" & integer'image(sb_samples) &
               " protocol errors=" & integer'image(udp_rx_errors + mac_tx_errors + arp_fifo_errors);

        assert timed_out = '0'
            report "TIMED OUT after " & time'image(TIMEOUT) &
                   " -- the design deadlocked or never stopped driving"
            severity failure;

        assert udp_rx_beats > 0
            report "nothing was delivered to udp_rx" severity failure;

        assert mac_tx_beats > 0
            report "nothing was transmitted on mac_tx" severity failure;

        assert (udp_rx_errors + mac_tx_errors + arp_fifo_errors) = 0
            report integer'image(udp_rx_errors + mac_tx_errors + arp_fifo_errors) &
                   " AXIS protocol violations"
            severity failure;

        std.env.stop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------------
    DUT: entity work.uoe
        port map (
            clk  => clk,
            rstn => rstn,

            mac_rx_tdata  => mac_rx.tdata,
            mac_rx_tkeep  => mac_rx.tkeep,
            mac_rx_tuser(0) => mac_rx.tuser,
            mac_rx_tvalid => mac_rx.tvalid,
            mac_rx_tlast  => mac_rx.tlast,
            mac_rx_tready => mac_rx_tready,

            udp_rx_tdata  => udp_rx.tdata,
            udp_rx_tkeep  => udp_rx.tkeep,
            udp_rx_tvalid => udp_rx.tvalid,
            udp_rx_tlast  => udp_rx.tlast,
            udp_rx_tuser  => udp_rx.tuser,

            udp_rx_src_mac  => udp_rx_src_mac,
            udp_rx_src_ip   => udp_rx_src_ip,
            udp_rx_src_port => udp_rx_src_port,
            udp_rx_dst_port => udp_rx_dst_port,

            mac_tx_tdata  => mac_tx.tdata,
            mac_tx_tkeep  => mac_tx.tkeep,
            mac_tx_tvalid => mac_tx.tvalid,
            mac_tx_tlast  => mac_tx.tlast,
            mac_tx_tready => mac_tx_tready,

            udp_tx_tdata  => udp_tx.tdata,
            udp_tx_tkeep  => udp_tx.tkeep,
            udp_tx_tvalid => udp_tx.tvalid,
            udp_tx_tlast  => udp_tx.tlast,
            udp_tx_tready => udp_tx_tready,

            conf_tx_dst_mac  => tx_dst_mac,
            conf_tx_dst_ip   => tx_dst_ip,
            conf_tx_dst_port => tx_dst_port,

            conf_mac  => CONF_MAC_C,
            conf_ip   => CONF_IP_C,
            conf_port => CONF_PORT_C
        );

    -- mac_tx has no tuser port; the record element still needs a driver.
    mac_tx.tuser <= '0';

end sim;
