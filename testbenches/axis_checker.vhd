-- Passive AXI-Stream protocol checker.
--
-- Drives nothing. Instantiate it on any AXIS interface -- DUT outputs, DUT
-- inputs, or internal interfaces inside uoe.vhd -- and it reports violations
-- at the cycle they happen. It knows nothing about payload correctness; that
-- is the file comparison's job. See testbenches/README.md.
--
-- For interfaces without a tready (the rx chain), tie tready to '1'. Every
-- stall-related rule then becomes vacuously true with no conditional logic.

library ieee;
use ieee.std_logic_1164.all;

use work.axis_pkg.all;

entity axis_checker is
    generic (
        NAME             : string  := "axis";   -- prefix on every message
        CHECK_KEEP_RULES : boolean := true;     -- off for non-byte-stream buses
        -- This design packs bytes MSB-first, so a partial beat keeps the HIGH
        -- lanes and tkeep reads F0, FC... The MAC-facing ports are the other
        -- way round (endianness_converter reverses tdata AND tkeep), where the
        -- same beat reads 0F. Set this on those buses or every partial beat is
        -- reported as a hole.
        KEEP_LSB_FIRST : boolean := false;
        -- tuser is a packet error flag here, legal only alongside tlast
        CHECK_TUSER_ON_TLAST : boolean := true;
        MAX_PACKET_BEATS : natural := 512       -- ~4KB at 8 bytes per beat
    );
    port (
        clk, rstn : in std_logic;

        axis   : in axis_beat_t;
        tready : in std_logic;                  -- tie to '1' if the interface has none

        errors : out natural                    -- read by the testbench at end of test
    );
end axis_checker;


architecture sim of axis_checker is

    -- previous-cycle snapshot, for the stability rules
    signal prev       : axis_beat_t := AXIS_IDLE;
    signal prev_ready : std_logic   := '1';

    signal beats_since_last : natural := 0;

    -- Set on the first rising edge, so the reset rule can skip that one edge.
    -- The RTL uses SYNCHRONOUS reset: an output flop holds 'U' until it has
    -- been clocked at least once, so at t=0 tvalid is legitimately unknown and
    -- checking it there flags every block in the design. From the second edge
    -- on the rule applies in full. Real hardware has no equivalent window --
    -- Xilinx GSR initialises every flop at configuration.
    signal clocked_once : std_logic := '0';

    -- Present tkeep to the shape rules in this design's MSB-first orientation,
    -- whichever way round the bus itself carries it.
    function orient(k : std_logic_vector) return std_logic_vector is
        variable r : std_logic_vector(k'range);
    begin
        if(not KEEP_LSB_FIRST) then
            return k;
        end if;
        for i in k'range loop
            r(k'high + k'low - i) := k(i);
        end loop;
        return r;
    end function;

begin

    check_proc: process(clk)

        -- a variable, not a signal: several checks can fail in the same cycle,
        -- and "errors <= errors + 1" three times in one process activation
        -- would only increment once (last assignment wins).
        variable err_count : natural := 0;

        -- declared after err_count so it can see it
        procedure check(constant cond : in boolean; constant msg : in string) is
        begin
            if(not cond) then
                report NAME & ": " & msg severity error;
                err_count := err_count + 1;
            end if;
        end procedure;

    begin
        if(rising_edge(clk)) then

            clocked_once <= '1';

            if(rstn = '0') then
                -- a block that asserts tvalid out of reset injects a garbage beat
                if(clocked_once = '1') then
                    check(axis.tvalid = '0', "tvalid asserted during reset");
                end if;
                beats_since_last <= 0;

            else
                ----------------------------------------------------------
                -- nothing may move while stalled
                -- (vacuous when tready is tied high)
                ----------------------------------------------------------
                if(prev.tvalid = '1' and prev_ready = '0') then
                    check(axis.tvalid = '1',        "tvalid withdrawn before handshake");
                    check(axis.tdata  = prev.tdata, "tdata changed while stalled");
                    check(axis.tkeep  = prev.tkeep, "tkeep changed while stalled");
                    check(axis.tlast  = prev.tlast, "tlast changed while stalled");
                    check(axis.tuser  = prev.tuser, "tuser changed while stalled");
                end if;
                -- note: tready has no stability rule. A slave may withdraw it
                -- on any cycle; asserting otherwise gives constant false fails.

                ----------------------------------------------------------
                -- nothing undriven
                ----------------------------------------------------------
                check(not is_x(axis.tvalid), "tvalid is X/U");

                if(axis.tvalid = '1') then
                    check(not is_x(axis.tlast), "tlast is X/U");
                    check(not is_x(axis.tkeep), "tkeep is X/U");
                    check(not is_x(axis.tuser), "tuser is X/U");

                    -- This design uses tuser as a PACKET-level error flag,
                    -- raised together with tlast to mark the packet just
                    -- delivered as invalid (see rx_ipv4 and rx_udp).
                    -- Asserting it mid-packet would mean something else
                    -- entirely, and no consumer here is written to expect it.
                    if(CHECK_TUSER_ON_TLAST and axis.tuser = '1') then
                        check(axis.tlast = '1',
                              "tuser asserted on a beat that is not tlast");
                    end if;

                    -- only kept lanes: null bytes are legitimately undefined
                    for byte in 0 to 7 loop
                        if(axis.tkeep(7-byte) = '1') then
                            check(not is_x(axis.tdata(63-8*byte downto 56-8*byte)),
                                  "tdata byte " & integer'image(byte) & " is X/U in a kept lane");
                        end if;
                    end loop;
                end if;

                ----------------------------------------------------------
                -- tkeep shape (this design's convention, not the AXI spec)
                ----------------------------------------------------------
                if(axis.tvalid = '1' and CHECK_KEEP_RULES) then
                    check(axis.tkeep /= x"00", "tvalid with tkeep = 0");
                    check(keep_is_contiguous(orient(axis.tkeep)),
                          "non-contiguous tkeep " & to_hstring(axis.tkeep));
                    check(axis.tkeep = x"FF" or axis.tlast = '1',
                          "partial tkeep " & to_hstring(axis.tkeep) & " on a non-last beat");
                end if;

                ----------------------------------------------------------
                -- tlast watchdog: counts handshakes, not cycles.
                -- A lost tlast does not corrupt data, it hangs the packet
                -- FIFO downstream forever with no indication of where.
                ----------------------------------------------------------
                if(axis.tvalid = '1' and tready = '1') then
                    if(axis.tlast = '1') then
                        beats_since_last <= 0;
                    else
                        -- "/=" not "<" so this reports exactly once, not every beat after
                        check(beats_since_last /= MAX_PACKET_BEATS,
                              "no tlast after " & integer'image(MAX_PACKET_BEATS) & " beats");
                        beats_since_last <= beats_since_last + 1;
                    end if;
                end if;

            end if;

            ----------------------------------------------------------
            -- snapshot for next cycle
            ----------------------------------------------------------
            prev       <= axis;
            prev_ready <= tready;

            errors <= err_count;
        end if;
    end process;

end sim;
