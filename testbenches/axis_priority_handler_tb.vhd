-- axis_priority_handler testbench.
--
-- The block merges two AXI-Stream inputs onto one output, giving s0 priority
-- and never switching mid-packet. It sits directly in front of mac_tx, so a
-- fault here reaches the wire.
--
-- Two drivers run concurrently -- that is the whole point. An arbiter driven
-- one stream at a time is not being arbitrated.
--
-- Nothing in the design fixes how the two streams interleave, so the capture
-- is split by the tag in payload byte 0 (0xA0 for s0, 0xB0 for s1) and each
-- stream is compared in order. That keeps every property that IS specified --
-- packets whole, in order within a stream, never interleaved -- and tests no
-- scheduling that is not. See reference_model/split_by_tag.py.
--
-- Test vectors come from reference_model/gen_axis_priority_handler.py.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity axis_priority_handler_tb is
    generic (
        STIMULUS_FILE : string  := "stimulus_axis_priority_handler_tb.txt";
        STIMULUS_S1   : string  := "stimulus_axis_priority_handler_tb_s1.txt";
        AXIS_FILE     : string  := "axis_axis_priority_handler_tb.txt";
        READY_PERCENT : integer := 100
    );
end axis_priority_handler_tb;


architecture sim of axis_priority_handler_tb is

    constant clk_period : time := 10 ns;

    constant IDLE_TO_FINISH : natural := 1000;
    constant TIMEOUT        : time    := 2 ms;

    signal clk, rstn : std_logic := '0';

    signal s0, s1, m_axis : axis_beat_t := AXIS_IDLE;
    signal s0_tready, s1_tready, m_tready : std_logic;

    signal s0_case_index, s1_case_index : natural;
    signal s0_case_name,  s1_case_name  : case_name_t;

    signal s0_done, s1_done : std_logic := '0';
    signal close_files      : std_logic := '0';
    signal timed_out        : std_logic := '0';
    signal axis_errors      : natural;
    signal beats, packets   : natural;

begin

    clk  <= not(clk) after clk_period/2;
    rstn <= '0', '1' after 10 * clk_period;

    ------------------------------------------------------------------
    -- two drivers, running at the same time
    ------------------------------------------------------------------
    drv_s0: entity work.axis_driver
        generic map (STIMULUS_FILE => STIMULUS_FILE)
        port map (
            clk => clk, rstn => rstn, axis => s0, tready => s0_tready,
            case_index => s0_case_index, case_name => s0_case_name,
            done => s0_done);

    drv_s1: entity work.axis_driver
        generic map (STIMULUS_FILE => STIMULUS_S1)
        port map (
            clk => clk, rstn => rstn, axis => s1, tready => s1_tready,
            case_index => s1_case_index, case_name => s1_case_name,
            done => s1_done);

    sink: entity work.axis_stall
        generic map (READY_PERCENT => READY_PERCENT, SEED1 => 31415, SEED2 => 926)
        port map (clk => clk, rstn => rstn, tready => m_tready);

    monitor: entity work.axis_monitor
        generic map (AXIS_FILE => AXIS_FILE)
        port map (
            clk => clk, axis => m_axis, tready => m_tready,
            close_file => close_files, beats => beats, packets => packets);

    -- 9000-byte packets are 1125 beats, so the default tlast watchdog would
    -- fire on a legitimate one.
    checker: entity work.axis_checker
        generic map (NAME => "priority.m_axis", MAX_PACKET_BEATS => 2048)
        port map (clk => clk, rstn => rstn, axis => m_axis, tready => m_tready,
                  errors => axis_errors);

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
        wait until (s0_done = '1' and s1_done = '1') or timed_out = '1';

        loop
            wait until rising_edge(clk);
            if(m_axis.tvalid = '1' and m_tready = '1') then
                idle := 0;
            else
                idle := idle + 1;
            end if;
            exit when idle >= IDLE_TO_FINISH or timed_out = '1';
        end loop;

        close_files <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "beats=" & integer'image(beats) &
               " packets=" & integer'image(packets) &
               " sideband=0" &
               " protocol errors=" & integer'image(axis_errors);

        assert timed_out = '0'
            report "TIMED OUT after " & time'image(TIMEOUT) &
                   " -- the arbiter deadlocked or never stopped driving"
            severity failure;

        assert beats > 0
            report "testbench produced no output at all" severity failure;

        assert axis_errors = 0
            report integer'image(axis_errors) &
                   " AXIS protocol violations on priority.m_axis"
            severity failure;

        std.env.stop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------------
    DUT: entity work.axis_priority_handler
        port map (
            clk  => clk,
            rstn => rstn,

            s0_axis_tdata  => s0.tdata,
            s0_axis_tkeep  => s0.tkeep,
            s0_axis_tvalid => s0.tvalid,
            s0_axis_tlast  => s0.tlast,
            s0_axis_tready => s0_tready,

            s1_axis_tdata  => s1.tdata,
            s1_axis_tkeep  => s1.tkeep,
            s1_axis_tvalid => s1.tvalid,
            s1_axis_tlast  => s1.tlast,
            s1_axis_tready => s1_tready,

            m_axis_tdata  => m_axis.tdata,
            m_axis_tkeep  => m_axis.tkeep,
            m_axis_tvalid => m_axis.tvalid,
            m_axis_tlast  => m_axis.tlast,
            m_axis_tready => m_tready
        );

    -- this block has no tuser; the record element needs a driver
    m_axis.tuser <= '0';

end sim;
