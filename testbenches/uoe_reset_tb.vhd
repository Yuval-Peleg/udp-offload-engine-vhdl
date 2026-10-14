-- uoe reset testbench. Not a data test -- it drives no packets and checks no
-- payloads. It exists to exercise one thing the per-block testbenches cannot:
-- the reset stretcher in uoe.vhd, which is above every block and so has no
-- other home.
--
-- Three stimuli, in order:
--
--   1. a normal power-on reset, held well past the requirement
--   2. a ONE-CYCLE glitch on rstn -- the case a plain 2-flop synchronizer
--      passes straight through and the XPM FIFOs' 4-deep reset CDC then
--      filters out entirely, leaving them un-reset while the logic around
--      them restarts
--   3. a short-but-not-minimal pulse
--
-- What it measures: how many clocks rstn_sync stays low for each. A stretcher
-- that works turns all three into at least MIN_RST_CLK.
--
-- xsim exits 0 even on a failed assertion, so the pass/fail signal is the
-- printed "protocol errors=N" line, same as every other testbench here.

library ieee;
use ieee.std_logic_1164.all;

entity uoe_reset_tb is
    generic (
        -- what uoe.vhd's stretcher is supposed to guarantee
        MIN_RST_CLK : natural := 64
    );
end uoe_reset_tb;


architecture sim of uoe_reset_tb is

    constant clk_period : time := 10 ns;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    -- everything below is tied off; this test never moves data
    signal mac_rx_tdata  : std_logic_vector(63 downto 0) := (others => '0');
    signal mac_rx_tkeep  : std_logic_vector(7 downto 0)  := (others => '0');
    signal mac_rx_tuser  : std_logic_vector(0 downto 0)  := (others => '0');
    signal mac_rx_tvalid : std_logic := '0';
    signal mac_rx_tlast  : std_logic := '0';
    signal mac_rx_tready : std_logic;

    signal udp_rx_tdata  : std_logic_vector(63 downto 0);
    signal udp_rx_tkeep  : std_logic_vector(7 downto 0);
    signal udp_rx_tvalid : std_logic;
    signal udp_rx_tlast  : std_logic;
    signal udp_rx_tuser  : std_logic;

    signal udp_rx_src_mac  : std_logic_vector(47 downto 0);
    signal udp_rx_src_ip   : std_logic_vector(31 downto 0);
    signal udp_rx_src_port : std_logic_vector(15 downto 0);
    signal udp_rx_dst_port : std_logic_vector(15 downto 0);

    signal mac_tx_tdata  : std_logic_vector(63 downto 0);
    signal mac_tx_tkeep  : std_logic_vector(7 downto 0);
    signal mac_tx_tvalid : std_logic;
    signal mac_tx_tlast  : std_logic;
    signal mac_tx_tready : std_logic := '1';

    signal udp_tx_tdata  : std_logic_vector(63 downto 0) := (others => '0');
    signal udp_tx_tkeep  : std_logic_vector(7 downto 0)  := (others => '0');
    signal udp_tx_tvalid : std_logic := '0';
    signal udp_tx_tlast  : std_logic := '0';
    signal udp_tx_tready : std_logic;

    signal conf_tx_dst_mac  : std_logic_vector(47 downto 0) := x"CAFEF00D0202";
    signal conf_tx_dst_ip   : std_logic_vector(31 downto 0) := x"C0A80164";
    signal conf_tx_dst_port : std_logic_vector(15 downto 0) := x"1234";

    signal conf_mac  : std_logic_vector(47 downto 0) := x"DECAFBAD0101";
    signal conf_ip   : std_logic_vector(31 downto 0) := x"C0A80101";
    signal conf_port : std_logic_vector(15 downto 0) := x"04D2";

    signal errors : natural := 0;

begin

    clk <= not(clk) after clk_period/2;

    ------------------------------------------------------------------
    -- stimulus
    ------------------------------------------------------------------
    stim: process
        -- rstn_sync is internal to uoe, so the probe is hierarchical.
        -- Count every clock rstn_sync spends low, from before the pulse until
        -- it has been high again for a while. Counting only AFTER rstn is
        -- released would miss the low cycles during the pulse and, worse,
        -- would read a not-yet-reacted rstn_sync as "already released" -- the
        -- stretcher is two flops behind its input by construction.
        procedure measure(name : in string; pulse_clocks : in natural) is
            variable held     : natural := 0;
            variable high_run : natural := 0;
            variable total    : natural := 0;
        begin
            rstn <= '1';
            for i in 0 to 20 loop
                wait until rising_edge(clk);
            end loop;

            -- Scheduled, not blocking, so the counting loop below runs across
            -- the whole pulse rather than starting after it. Offset by half a
            -- period: a pulse that both starts and ends exactly on rising
            -- edges falls between them and is never sampled at all -- that is
            -- a property of synchronous sampling, not of the DUT, and it would
            -- make a 1-clock test look like a failure for the wrong reason.
            rstn <= '0' after clk_period/2,
                    '1' after clk_period/2 + pulse_clocks * clk_period;

            held := 0; high_run := 0; total := 0;
            loop
                wait until rising_edge(clk);
                total := total + 1;
                if(<< signal .uoe_reset_tb.DUT.rstn_sync : std_logic >> = '0') then
                    held := held + 1;
                    high_run := 0;
                else
                    high_run := high_run + 1;
                end if;
                exit when (high_run >= 16) or (total > 6 * MIN_RST_CLK);
            end loop;

            report name & ": rstn low for " & integer'image(pulse_clocks) &
                   " clk -> rstn_sync low for " & integer'image(held) & " clk";

            -- Too short is a failure. So is never coming back: a stretcher that
            -- reloads its own counter forever holds the whole design in reset,
            -- and "held >= MIN_RST_CLK" on its own cannot tell the two apart.
            if(<< signal .uoe_reset_tb.DUT.rstn_sync : std_logic >> /= '1') then
                errors <= errors + 1;
                report name & ": rstn_sync NEVER released -- still low after " &
                       integer'image(total) & " clocks"
                    severity error;
            elsif(held < MIN_RST_CLK) then
                errors <= errors + 1;
                report name & ": stretcher gave " & integer'image(held) &
                       " clocks, needs at least " & integer'image(MIN_RST_CLK)
                    severity error;
            end if;
        end procedure;
    begin
        measure("power-on   ", 100);
        measure("1-clk glitch", 1);
        measure("5-clk pulse ", 5);

        wait until rising_edge(clk);
        report "uoe reset stretcher: protocol errors=" & integer'image(errors);
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

            mac_rx_tdata  => mac_rx_tdata,
            mac_rx_tkeep  => mac_rx_tkeep,
            mac_rx_tuser  => mac_rx_tuser,
            mac_rx_tvalid => mac_rx_tvalid,
            mac_rx_tlast  => mac_rx_tlast,
            mac_rx_tready => mac_rx_tready,

            udp_rx_tdata  => udp_rx_tdata,
            udp_rx_tkeep  => udp_rx_tkeep,
            udp_rx_tvalid => udp_rx_tvalid,
            udp_rx_tlast  => udp_rx_tlast,
            udp_rx_tuser  => udp_rx_tuser,

            udp_rx_src_mac  => udp_rx_src_mac,
            udp_rx_src_ip   => udp_rx_src_ip,
            udp_rx_src_port => udp_rx_src_port,
            udp_rx_dst_port => udp_rx_dst_port,

            mac_tx_tdata  => mac_tx_tdata,
            mac_tx_tkeep  => mac_tx_tkeep,
            mac_tx_tvalid => mac_tx_tvalid,
            mac_tx_tlast  => mac_tx_tlast,
            mac_tx_tready => mac_tx_tready,

            udp_tx_tdata  => udp_tx_tdata,
            udp_tx_tkeep  => udp_tx_tkeep,
            udp_tx_tvalid => udp_tx_tvalid,
            udp_tx_tlast  => udp_tx_tlast,
            udp_tx_tready => udp_tx_tready,

            conf_tx_dst_mac  => conf_tx_dst_mac,
            conf_tx_dst_ip   => conf_tx_dst_ip,
            conf_tx_dst_port => conf_tx_dst_port,

            conf_mac  => conf_mac,
            conf_ip   => conf_ip,
            conf_port => conf_port
        );

end sim;
