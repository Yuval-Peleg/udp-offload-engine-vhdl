-- arp_handler testbench.
--
-- The full-chip test sends only a few frames this block must ignore, so this
-- test covers every REJECTION path. That is most of the block: the receive FSM is
-- seven states of "does this field match, or dump", and a check that is too
-- loose answers frames it should ignore -- which on a real network means
-- replying for an address that is not ours.
--
-- The stimulus violates one field at a time and follows each rejection with a
-- good request. That ordering is the point: a rejection that leaves the FSM in
-- the wrong state shows up as the NEXT request going unanswered, not as the
-- bad one being answered.
--
-- Neither port has a tready. The input cannot be stalled because the block is
-- fed from the RX path, and the output has no handshake at all -- so
-- axis_checker's stability rules are vacuous here, but its tlast, tkeep and
-- X-propagation rules are not.
--
-- Test vectors come from reference_model/gen_arp_handler.py.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity arp_handler_tb is
    generic (
        STIMULUS_FILE : string  := "stimulus_arp_handler_tb.txt";
        AXIS_FILE     : string  := "axis_arp_handler_tb.txt";
        -- accepted for interface compatibility with the other blocks; this
        -- one has no output handshake to stall
        READY_PERCENT : integer := 100
    );
end arp_handler_tb;


architecture sim of arp_handler_tb is

    constant clk_period : time := 10 ns;

    -- must match reference_model/gen_arp_handler.py
    constant CONF_MAC_C : std_logic_vector(47 downto 0) := x"DECAFBAD0101";
    constant CONF_IP_C  : std_logic_vector(31 downto 0) := x"C0A80101";

    constant IDLE_TO_FINISH : natural := 200;
    constant TIMEOUT        : time    := 500 us;

    signal clk, rstn : std_logic := '0';

    signal s_axis, m_axis : axis_beat_t := AXIS_IDLE;

    signal case_index : natural;
    signal case_name  : case_name_t;

    signal drv_done, close_files : std_logic := '0';
    signal timed_out             : std_logic := '0';
    signal axis_errors           : natural;
    signal beats, packets        : natural;

begin

    clk  <= not(clk) after clk_period/2;
    rstn <= '0', '1' after 10 * clk_period;

    ------------------------------------------------------------------
    -- verification components
    ------------------------------------------------------------------
    -- The block has no s_axis_tready, so the driver is told the sink is always
    -- ready: one beat per cycle, exactly as the RX path delivers.
    driver: entity work.axis_driver
        generic map (STIMULUS_FILE => STIMULUS_FILE)
        port map (
            clk => clk, rstn => rstn,
            axis => s_axis, tready => '1',
            case_index => case_index, case_name => case_name,
            done => drv_done);

    monitor: entity work.axis_monitor
        generic map (AXIS_FILE => AXIS_FILE)
        port map (
            clk => clk, axis => m_axis, tready => '1',
            close_file => close_files, beats => beats, packets => packets);

    checker: entity work.axis_checker
        generic map (NAME => "arp_handler.m_axis")
        port map (clk => clk, rstn => rstn, axis => m_axis, tready => '1',
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
            if(m_axis.tvalid = '1') then
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
                   " -- the block deadlocked or never stopped driving"
            severity failure;

        assert beats > 0
            report "no ARP reply was produced at all" severity failure;

        assert axis_errors = 0
            report integer'image(axis_errors) &
                   " AXIS protocol violations on arp_handler.m_axis"
            severity failure;

        std.env.stop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------------
    DUT: entity work.arp_handler
        port map (
            clk  => clk,
            rstn => rstn,

            s_axis_tdata  => s_axis.tdata,
            s_axis_tkeep  => s_axis.tkeep,
            s_axis_tvalid => s_axis.tvalid,
            s_axis_tlast  => s_axis.tlast,

            m_axis_tdata  => m_axis.tdata,
            m_axis_tkeep  => m_axis.tkeep,
            m_axis_tvalid => m_axis.tvalid,
            m_axis_tlast  => m_axis.tlast,

            -- the drop-on-full path belongs to uoe, where a real FIFO drives
            -- this; held inactive so the block is tested on its own terms
            prog_full_flag => '0',

            conf_mac => CONF_MAC_C,
            conf_ip  => CONF_IP_C
        );

    -- this block produces no tuser; the record element needs a driver
    m_axis.tuser <= '0';

end sim;
