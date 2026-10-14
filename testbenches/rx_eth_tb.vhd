-- rx_eth testbench, built on the reusable AXIS verification components.
-- See testbenches/README.md.
--
-- rx_eth has no tready (nothing in the rx chain does), so every AXIS
-- component gets tready tied to '1'.
--
-- Test vectors come from reference_model/gen_rx_eth.py. CONFIGURED_MAC below
-- must match CONF_MAC there.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity rx_eth_tb is
    generic (
        STIMULUS_FILE : string := "stimulus_rx_eth_tb.txt";
        AXIS_FILE     : string := "axis_rx_eth_tb.txt";
        SIDEBAND_FILE : string := "sideband_rx_eth_tb.txt"
    );
end rx_eth_tb;


architecture sim of rx_eth_tb is

    ----------------------------------------------------------
    -- constants
    ----------------------------------------------------------
    constant clk_period : time := 10 ns;

    -- locally-administered MAC -- must match CONF_MAC in gen_rx_eth.py
    constant CONFIGURED_MAC : std_logic_vector(47 downto 0) := x"02DEADBEEF01";

    ----------------------------------------------------------
    -- internal signals
    ----------------------------------------------------------
    signal clk, rstn : std_logic := '0';

    -- DUT buses. s_axis is driven by axis_driver, m_axis by the DUT.
    signal s_axis, m_axis : axis_beat_t := AXIS_IDLE;

    -- rx path has no tready
    signal always_ready : std_logic := '1';

    -- configs
    signal conf_mac : std_logic_vector(47 downto 0) := CONFIGURED_MAC;

    -- retrieved data
    signal src_mac    : std_logic_vector(47 downto 0);
    signal sb_trigger : std_logic;

    -- which test case the driver is currently playing, for the waveform
    signal case_index : natural;
    signal case_name  : case_name_t;

    -- test control and results
    signal drv_done, close_files : std_logic := '0';
    signal axis_errors           : natural;
    signal beats, packets        : natural;
    signal sideband_samples      : natural;

begin

    ------------------------------------------------------------------
    -- clock and reset
    ------------------------------------------------------------------
    clk  <= not(clk) after clk_period/2;
    rstn <= '0', '1' after 10 * clk_period;

    -- rx_eth has no tuser output. The record element still needs a
    -- driver, and '0' is the honest value: no packet it emits is
    -- flagged invalid. Record elements may be driven separately from
    -- the rest of the record, which the DUT drives via its port map.
    m_axis.tuser <= '0';

    -- src_mac is latched by the DUT, so sample it on the last beat of a packet
    sb_trigger <= m_axis.tvalid and m_axis.tlast;

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
            tready     => always_ready,
            case_index => case_index,
            case_name  => case_name,
            done       => drv_done
        );

    monitor: entity work.axis_monitor
        generic map (
            AXIS_FILE => AXIS_FILE
        )
        port map (
            clk        => clk,
            axis       => m_axis,
            tready     => always_ready,
            close_file => close_files,
            beats      => beats,
            packets    => packets
        );

    sideband: entity work.sideband_monitor
        generic map (
            SIDEBAND_FILE => SIDEBAND_FILE,
            WIDTH         => 48
        )
        port map (
            clk        => clk,
            trigger    => sb_trigger,
            value      => src_mac,
            close_file => close_files,
            samples    => sideband_samples
        );

    checker: entity work.axis_checker
        generic map (
            NAME => "rx_eth.m_axis"
        )
        port map (
            clk    => clk,
            rstn   => rstn,
            axis   => m_axis,
            tready => always_ready,
            errors => axis_errors
        );

    ------------------------------------------------------------------
    -- test control
    ------------------------------------------------------------------
    control_proc: process
    begin
        wait until drv_done = '1';

        -- let the last packet drain out of the DUT
        for i in 1 to 20 loop
            wait until rising_edge(clk);
        end loop;

        -- Close the files before any assertion can abort the simulation, so a
        -- failure still leaves a complete output file to diff. Two edges, not
        -- one: the monitors close on the first, and process execution order
        -- within a single delta is undefined -- std.env.stop could otherwise
        -- run before they got the chance.
        close_files <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "beats=" & integer'image(beats) &
               " packets=" & integer'image(packets) &
               " sideband=" & integer'image(sideband_samples) &
               " protocol errors=" & integer'image(axis_errors);

        -- the most common way a testbench lies to you is by silently doing
        -- nothing: wrong filename, driver stuck in reset, empty stimulus
        assert beats > 0
            report "testbench produced no output at all" severity failure;

        assert axis_errors = 0
            report integer'image(axis_errors) & " AXIS protocol violations on rx_eth.m_axis"
            severity failure;

        std.env.stop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- port mapping components
    ------------------------------------------------------------------
    DUT: entity work.rx_eth
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

            conf_mac => conf_mac,

            src_mac => src_mac
        );

end sim;
