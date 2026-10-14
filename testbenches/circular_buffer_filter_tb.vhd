-- circular_buffer_filter testbench.
--
-- This block drops frames the MAC flagged and frames too big to buffer. A
-- frame larger than the buffer must be dropped whole; if it is not, it wedges the
-- whole receive path.
--
-- Two things make it different from the other block tests:
--
--   * tuser is an INPUT here, not an output. It is the MAC's error flag,
--     raised with tlast to condemn the frame it ends. Every other block in
--     this design either ignores tuser or produces it; this one consumes it.
--
--   * the interesting behaviour is what does NOT come out. A dropped frame is
--     correct; a dropped frame that leaves the pointers inconsistent shows up
--     as the NEXT frame being mangled, so the stimulus follows every drop with
--     a known-good frame and the comparison checks that one arrives intact.
--
-- The output is fully handshaked, so axis_checker's stability rules are live.
--
-- Test vectors come from reference_model/gen_circular_buffer_filter.py.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity circular_buffer_filter_tb is
    generic (
        STIMULUS_FILE : string  := "stimulus_circular_buffer_filter_tb.txt";
        AXIS_FILE     : string  := "axis_circular_buffer_filter_tb.txt";
        -- 100 = never stall. Lower values put the block's output holding under
        -- test, and make the buffer fill, which is what the drop guard is for.
        READY_PERCENT : integer := 100
    );
end circular_buffer_filter_tb;


architecture sim of circular_buffer_filter_tb is

    constant clk_period : time := 10 ns;

    -- Generous; the block itself resets in one clock.
    constant RESET_CLOCKS : natural := 32;

    -- A full-capacity frame is 2048 beats and the oversized one is 2098, so
    -- the tail is long even without stalling.
    constant IDLE_TO_FINISH : natural := 2000;
    constant TIMEOUT        : time    := 2 ms;

    signal clk, rstn : std_logic := '0';

    signal s_axis, m_axis : axis_beat_t := AXIS_IDLE;
    signal s_tready, m_tready : std_logic;

    signal case_index : natural;
    signal case_name  : case_name_t;

    signal drv_done, close_files : std_logic := '0';
    signal timed_out             : std_logic := '0';
    signal axis_errors           : natural;
    signal beats, packets        : natural;

begin

    clk  <= not(clk) after clk_period/2;
    rstn <= '0', '1' after RESET_CLOCKS * clk_period;

    ------------------------------------------------------------------
    -- verification components
    ------------------------------------------------------------------
    driver: entity work.axis_driver
        generic map (STIMULUS_FILE => STIMULUS_FILE)
        port map (
            clk => clk, rstn => rstn,
            axis => s_axis, tready => s_tready,
            case_index => case_index, case_name => case_name,
            done => drv_done);

    sink: entity work.axis_stall
        generic map (READY_PERCENT => READY_PERCENT, SEED1 => 5150, SEED2 => 2718)
        port map (clk => clk, rstn => rstn, tready => m_tready);

    monitor: entity work.axis_monitor
        generic map (AXIS_FILE => AXIS_FILE)
        port map (
            clk => clk, axis => m_axis, tready => m_tready,
            close_file => close_files, beats => beats, packets => packets);

    -- MAX_PACKET_BEATS must clear the full-capacity frame, which is 2048 beats
    -- of legitimate packet.
    checker: entity work.axis_checker
        generic map (NAME => "circ_filter.m_axis", MAX_PACKET_BEATS => 4096)
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
        wait until drv_done = '1' or timed_out = '1';

        loop
            wait until rising_edge(clk);
            if(m_axis.tvalid = '1' and m_tready = '1') then
                idle := 0;
            else
                idle := idle + 1;
            end if;
            exit when idle >= IDLE_TO_FINISH or timed_out = '1';
        end loop;

        -- Close before any assertion can abort, so a failure still leaves a
        -- complete file to diff. Two edges: process order within one delta is
        -- undefined.
        close_files <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "beats=" & integer'image(beats) &
               " packets=" & integer'image(packets) &
               " sideband=0" &
               " protocol errors=" & integer'image(axis_errors);

        assert timed_out = '0'
            report "TIMED OUT after " & time'image(TIMEOUT) &
                   " -- the block deadlocked or never stopped driving"
            severity failure;

        assert beats > 0
            report "testbench produced no output at all" severity failure;

        assert axis_errors = 0
            report integer'image(axis_errors) &
                   " AXIS protocol violations on circ_filter.m_axis"
            severity failure;

        std.env.stop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------------
    DUT: entity work.circular_buffer_filter
        port map (
            clk  => clk,
            rstn => rstn,

            s_axis_tdata  => s_axis.tdata,
            s_axis_tkeep  => s_axis.tkeep,
            s_axis_tvalid => s_axis.tvalid,
            s_axis_tlast  => s_axis.tlast,
            s_axis_tuser  => s_axis.tuser,
            s_axis_tready => s_tready,

            m_axis_tdata  => m_axis.tdata,
            m_axis_tkeep  => m_axis.tkeep,
            m_axis_tvalid => m_axis.tvalid,
            m_axis_tlast  => m_axis.tlast,
            m_axis_tready => m_tready
        );

    -- this block does not produce tuser; the record element needs a driver
    m_axis.tuser <= '0';

end sim;
