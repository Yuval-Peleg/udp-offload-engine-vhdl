-- tx_ipv4 testbench, built on the reusable AXIS verification components.
-- See testbenches/README.md.
--
-- Unlike the rx blocks, which have no tready, both sides handshake here:
--
--   * axis_driver holds each beat until the DUT raises s_axis_tready
--   * axis_stall drives m_axis_tready at READY_PERCENT, so the DUT has to
--     hold its output beat unchanged until we accept it -- which is exactly
--     what axis_checker's "changed while stalled" rules test
--
-- The expected file is shared by every variant. Neither input timing nor
-- output backpressure may change a single byte; if they do, that is the bug.
--
-- tx_ipv4 prepends a 20-byte header, so the payload lands 4 bytes out of
-- alignment and every output beat is stitched from two input words. It also
-- computes the RFC 1071 header checksum, and its Identification field
-- increments once per packet -- so a single dropped or duplicated packet
-- shifts the id and invalidates the checksum of every packet after it.
--
-- Test vectors come from reference_model/gen_tx_ipv4.py. The constants below
-- must match CONF_IP and DST_IP there.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity tx_ipv4_tb is
    generic (
        STIMULUS_FILE : string  := "stimulus_tx_ipv4_tb.txt";
        AXIS_FILE     : string  := "axis_tx_ipv4_tb.txt";
        -- 100 = never stall. Lower values make the sink refuse beats at
        -- random, which is what puts the DUT's output holding under test.
        READY_PERCENT : integer := 100
    );
end tx_ipv4_tb;


architecture sim of tx_ipv4_tb is

    ----------------------------------------------------------
    -- constants
    ----------------------------------------------------------
    constant clk_period : time := 10 ns;

    -- must match reference_model/gen_tx_ipv4.py
    constant CONFIGURED_IP  : std_logic_vector(31 downto 0) := x"C0A80164";
    constant DESTINATION_IP : std_logic_vector(31 downto 0) := x"C0A80101";

    -- How long the output may be silent before we call the DUT drained. It is
    -- store-and-forward and can be stalled by axis_stall, so this has to be
    -- generous -- a fixed short drain would truncate the last packet.
    constant IDLE_TO_FINISH : natural := 500;

    -- Hard stop. A DUT that deadlocks never raises drv_done, and one that gets
    -- stuck asserting tvalid emits a beat every cycle forever -- either way
    -- `xsim -runall` would run until it is killed. This bounds the damage to
    -- seconds and turns a hang into an ordinary reported failure.
    constant TIMEOUT : time := 800 us;

    ----------------------------------------------------------
    -- internal signals
    ----------------------------------------------------------
    signal clk, rstn : std_logic := '0';

    -- s_axis is driven by axis_driver, m_axis by the DUT
    signal s_axis, m_axis : axis_beat_t := AXIS_IDLE;

    -- real handshakes on both sides, unlike every rx testbench
    signal s_tready : std_logic;    -- DUT -> driver
    signal m_tready : std_logic;    -- axis_stall -> DUT

    signal conf_ip : std_logic_vector(31 downto 0) := CONFIGURED_IP;
    signal dst_ip  : std_logic_vector(31 downto 0) := DESTINATION_IP;

    -- the destination arrives on s_axis_tuser as mac & ip (tx_udp's layout);
    -- the mac passes through to m_axis_tuser for tx_eth. Fixed here:
    -- per-packet changes are tested at full chip, in uoe_tb_full.
    constant DESTINATION_MAC : std_logic_vector(47 downto 0) := x"CAFEF00D0202";
    signal m_tuser      : std_logic_vector(47 downto 0);
    signal tuser_errors : natural := 0;

    -- which test case the driver is currently playing, for the waveform
    signal case_index : natural;
    signal case_name  : case_name_t;

    -- test control and results
    signal drv_done, close_files : std_logic := '0';
    signal timed_out             : std_logic := '0';
    signal axis_errors           : natural;
    signal beats, packets        : natural;

begin

    ------------------------------------------------------------------
    -- clock and reset
    ------------------------------------------------------------------
    clk  <= not(clk) after clk_period/2;
    -- 32, not the 10 the rx testbenches use. The XPM AXIS FIFO in packet mode
    -- keeps an internal packet counter that is ONLY ever initialised by its
    -- reset; until it is, m_axis_tvalid is gated off and the FIFO looks empty
    -- forever. It needs about 11 clocks of reset; 32 is margin, not the
    -- minimum.
    rstn <= '0', '1' after 32 * clk_period;

    ------------------------------------------------------------------
    -- verification components
    ------------------------------------------------------------------
    driver: entity work.axis_driver
        generic map (
            STIMULUS_FILE => STIMULUS_FILE
        )
        port map (
            clk        => clk,
            rstn       => rstn,
            axis       => s_axis,
            tready     => s_tready,
            case_index => case_index,
            case_name  => case_name,
            done       => drv_done
        );

    -- the sink. READY_PERCENT = 100 makes it transparent, so the same
    -- component covers both the backpressure and the no-backpressure runs.
    sink: entity work.axis_stall
        generic map (
            READY_PERCENT => READY_PERCENT,
            SEED1         => 12345,
            SEED2         => 6789
        )
        port map (
            clk    => clk,
            rstn   => rstn,
            tready => m_tready
        );

    monitor: entity work.axis_monitor
        generic map (
            AXIS_FILE => AXIS_FILE
        )
        port map (
            clk        => clk,
            axis       => m_axis,
            tready     => m_tready,
            close_file => close_files,
            beats      => beats,
            packets    => packets
        );

    checker: entity work.axis_checker
        generic map (
            NAME => "tx_ipv4.m_axis"
        )
        port map (
            clk    => clk,
            rstn   => rstn,
            axis   => m_axis,
            tready => m_tready,
            errors => axis_errors
        );

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

        -- Drain by watching the output rather than counting a fixed number of
        -- clocks: how long the tail takes depends on the packet size and on
        -- how hard axis_stall is stalling, neither of which is known here.
        loop
            wait until rising_edge(clk);
            if(m_axis.tvalid = '1' and m_tready = '1') then
                idle := 0;
            else
                idle := idle + 1;
            end if;
            exit when idle >= IDLE_TO_FINISH or timed_out = '1';
        end loop;

        -- Close the files before any assertion can abort the simulation, so a
        -- failure still leaves a complete output file to diff. Two edges, not
        -- one: the monitors close on the first, and process execution order
        -- within a single delta is undefined.
        close_files <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "beats=" & integer'image(beats) &
               " packets=" & integer'image(packets) &
               " sideband=0" &
               " protocol errors=" & integer'image(axis_errors + tuser_errors);

        assert timed_out = '0'
            report "TIMED OUT after " & time'image(TIMEOUT) &
                   " -- the DUT deadlocked or never stopped driving"
            severity failure;

        assert beats > 0
            report "testbench produced no output at all" severity failure;

        assert axis_errors + tuser_errors = 0
            report integer'image(axis_errors) & " AXIS protocol violations, " &
                   integer'image(tuser_errors) & " wrong tuser on tx_ipv4.m_axis"
            severity failure;

        std.env.stop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- port mapping components
    ------------------------------------------------------------------
    DUT: entity work.tx_ipv4
        port map (
            clk  => clk,
            rstn => rstn,

            s_axis_tdata  => s_axis.tdata,
            s_axis_tkeep  => s_axis.tkeep,
            s_axis_tvalid => s_axis.tvalid,
            s_axis_tlast  => s_axis.tlast,
            s_axis_tready => s_tready,

            m_axis_tdata  => m_axis.tdata,
            m_axis_tkeep  => m_axis.tkeep,
            m_axis_tvalid => m_axis.tvalid,
            m_axis_tlast  => m_axis.tlast,
            m_axis_tready => m_tready,
            s_axis_tuser  => DESTINATION_MAC & dst_ip,
            m_axis_tuser  => m_tuser,

            conf_ip => conf_ip
        );

    -- axis_beat_t's tuser is the 1-bit error flag; tx_ipv4's is the 48-bit
    -- destination mac, checked below instead.
    m_axis.tuser <= '0';

    -- every accepted beat must carry the mac, not just the first: tx_eth's
    -- packet FIFO reads it from whichever beat is at its head.
    tuser_check: process(clk)
    begin
        if(rising_edge(clk)) then
            if(m_axis.tvalid = '1' and m_tready = '1' and m_tuser /= DESTINATION_MAC) then
                report "tx_ipv4.m_axis: tuser " & to_hstring(m_tuser) & " is not the mac"
                    severity error;
                tuser_errors <= tuser_errors + 1;
            end if;
        end if;
    end process;

end sim;
