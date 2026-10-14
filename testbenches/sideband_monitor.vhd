-- Logs a latched non-AXIS output (rx_udp's src_port, a MAC, an IP) to a text
-- file, one hex line per trigger event. The testbench triggers it once per
-- packet, on the first or the last beat. See testbenches/README.md.
--
-- WIDTH must be a multiple of 4: hwrite on a vector whose length is not is an
-- error. 16-bit ports and 48-bit MACs are fine.

library ieee;
use ieee.std_logic_1164.all;

use ieee.std_logic_textio.all;
use std.textio.all;

entity sideband_monitor is
    generic (
        SIDEBAND_FILE : string;
        WIDTH         : positive := 16
    );
    port (
        clk : in std_logic;

        trigger : in std_logic;                                 -- once per packet
        value   : in std_logic_vector(WIDTH-1 downto 0);

        close_file : in std_logic;

        samples : out natural
    );
end sideband_monitor;


architecture sim of sideband_monitor is

    file sideband_out : text open write_mode is SIDEBAND_FILE;

begin

    capture_proc: process(clk)

        variable row       : line;
        variable n_samples : natural := 0;
        variable closed    : boolean := false;

    begin
        if(rising_edge(clk)) then

            if(trigger = '1') then
                hwrite(row, value);
                writeline(sideband_out, row);
                n_samples := n_samples + 1;
            end if;

            if(close_file = '1' and not closed) then
                file_close(sideband_out);
                closed := true;
            end if;

            samples <= n_samples;
        end if;
    end process;

end sim;
