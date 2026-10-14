-- Passive AXI-Stream monitor: logs one line per valid beat to a text file,
-- in the format reference_model/compare_beats.py expects:
--
--     tdata(16 hex)  tkeep(2 hex)  tlast(0|1)  tuser(0|1)
--
-- Drives nothing on the bus. See testbenches/README.md.
--
-- Logs the handshake (tvalid and tready), not just tvalid. With tready tied
-- to '1' the two are identical, so interfaces without a tready are unaffected.
-- On an interface that does stall, logging tvalid alone would write the same
-- beat once per stalled cycle.

library ieee;
use ieee.std_logic_1164.all;

use ieee.std_logic_textio.all;
use std.textio.all;

use work.axis_pkg.all;

entity axis_monitor is
    generic (
        -- A DUT stuck asserting tvalid emits a beat every cycle. The cap
        -- stops the monitor from logging until the disk fills.
        MAX_BEATS : natural := 20000;
        AXIS_FILE : string
    );
    port (
        clk : in std_logic;

        axis   : in axis_beat_t;
        tready : in std_logic;              -- tie to '1' if the interface has none

        -- the monitor owns the file, so the testbench cannot close it; pulse
        -- this before std.env.stop instead of relying on the simulator to
        -- flush on exit
        close_file : in std_logic;

        beats   : out natural;
        packets : out natural
    );
end axis_monitor;


architecture sim of axis_monitor is

    file     axis_out : text open write_mode is AXIS_FILE;
    constant SPACE    : string := " ";

begin

    capture_proc: process(clk)

        variable row       : line;
        variable n_beats   : natural := 0;
        variable n_packets : natural := 0;
        variable closed    : boolean := false;

    begin
        if(rising_edge(clk)) then

            -- every completed handshake
            -- past MAX_BEATS the DUT is clearly runaway; stop writing so the
            -- file stays diffable, and say so once.
            if(axis.tvalid = '1' and tready = '1' and n_beats < MAX_BEATS) then
                hwrite(row, axis.tdata);
                write(row, SPACE);
                hwrite(row, axis.tkeep);
                write(row, SPACE);
                write(row, axis.tlast);
                write(row, SPACE);
                write(row, axis.tuser);
                writeline(axis_out, row);

                n_beats := n_beats + 1;
                if(axis.tlast = '1') then
                    n_packets := n_packets + 1;
                end if;
                if(n_beats = MAX_BEATS) then
                    report "axis_monitor: stopped logging after " &
                           integer'image(MAX_BEATS) & " beats -- output is runaway"
                           severity warning;
                end if;
            end if;

            -- after the write, so a beat landing on the same edge is not lost.
            -- close_file usually stays high once asserted, hence the flag.
            if(close_file = '1' and not closed) then
                file_close(axis_out);
                closed := true;
            end if;

            beats   <= n_beats;
            packets <= n_packets;
        end if;
    end process;

end sim;
