-- rx_udp testbench, built on the reusable AXIS verification components.
-- See testbenches/README.md.
--
-- Everything that is not specific to rx_udp lives in axis_driver / axis_monitor
-- / sideband_monitor / axis_checker. What remains here is the DUT, its sideband
-- sampling, and the end-of-test sequencing.
--
-- rx_udp has no config input: it forwards every datagram and reports dst_port
-- rather than filtering on it, so one rx chain can feed several consumers.
--
-- rx_udp has no tready (the XXV MAC does not provide one), so every AXIS
-- component gets tready tied to '1'.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity rx_udp_tb is
    generic (
        STIMULUS_FILE : string := "stimulus_rx_udp_tb.txt";
        AXIS_FILE     : string := "axis_rx_udp_tb.txt";
        SIDEBAND_FILE : string := "sideband_rx_udp_tb.txt"
    );
end rx_udp_tb;


architecture sim of rx_udp_tb is

    ----------------------------------------------------------
    -- constants
    ----------------------------------------------------------
    constant clk_period : time := 10 ns;

    ----------------------------------------------------------
    -- internal signals
    ----------------------------------------------------------
    signal clk, rstn : std_logic := '0';

    -- DUT buses. s_axis is driven by axis_driver, m_axis by the DUT.
    signal s_axis, m_axis : axis_beat_t := AXIS_IDLE;

    -- rx path has no tready
    signal always_ready : std_logic := '1';

    -- rx_udp takes no config: it does not filter on destination port, it
    -- reports it. Deciding which consumer inside the fabric wants a packet is
    -- a demux job, not a parsing job.

    -- retrieved data. Both ports are latched from the same header word, so
    -- both are valid from the first payload beat onwards.
    signal src_port   : std_logic_vector(15 downto 0);
    signal dst_port   : std_logic_vector(15 downto 0);
    signal sb_value   : std_logic_vector(31 downto 0);
    signal sb_trigger : std_logic;

    -- High when the next valid output beat will be the FIRST of a packet.
    signal sop : std_logic := '1';

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

    ------------------------------------------------------------------
    -- sideband sampling
    ------------------------------------------------------------------
    -- Sampled on the FIRST beat of each output packet, not on tlast.
    --
    -- dst_port is a ROUTING signal: a downstream demux has to decide where
    -- beat 0 goes at the moment beat 0 appears, so a value that is only correct
    -- by tlast is a packet too late to be useful. Sampling at start-of-packet
    -- is what makes this testbench able to tell those two cases apart.
    --
    -- src_port rides along in the same 32-bit word purely so one monitor and
    -- one expected file cover both; it is equally valid at this point, being
    -- latched from the same header word.
    sop_proc: process(clk)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                sop <= '1';
            elsif(m_axis.tvalid = '1') then
                sop <= m_axis.tlast;
            end if;
        end if;
    end process;

    sb_trigger <= m_axis.tvalid and sop;
    sb_value   <= dst_port & src_port;



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
            WIDTH         => 32
        )
        port map (
            clk        => clk,
            trigger    => sb_trigger,
            value      => sb_value,
            close_file => close_files,
            samples    => sideband_samples
        );

    checker: entity work.axis_checker
        generic map (
            NAME => "rx_udp.m_axis"
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
            report integer'image(axis_errors) & " AXIS protocol violations on rx_udp.m_axis"
            severity failure;

        std.env.stop;
        wait;
    end process;

    ------------------------------------------------------------------
    -- port mapping components
    ------------------------------------------------------------------
    DUT: entity work.rx_udp
        port map (
            clk  => clk,
            rstn => rstn,

            s_axis_tdata  => s_axis.tdata,
            s_axis_tkeep  => s_axis.tkeep,
            s_axis_tvalid => s_axis.tvalid,
            s_axis_tlast  => s_axis.tlast,
            -- the stimulus file's tuser column: some packets arrive already
            -- flagged by rx_ipv4, and rx_udp must pass the flag on
            s_axis_tuser  => s_axis.tuser,

            m_axis_tdata  => m_axis.tdata,
            m_axis_tkeep  => m_axis.tkeep,
            m_axis_tvalid => m_axis.tvalid,
            m_axis_tlast  => m_axis.tlast,
            m_axis_tuser  => m_axis.tuser,

            src_port => src_port,
            dst_port => dst_port
        );

end sim;
