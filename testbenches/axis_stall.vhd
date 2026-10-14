-- Drives tready with a reproducible random pattern, to backpressure a DUT
-- output. See testbenches/README.md.
--
--   READY_PERCENT = 100  never stalls (so this entity also covers the
--                        no-backpressure case -- no separate tie-off needed)
--   READY_PERCENT =  50  ordinary interleaved stalling
--   READY_PERCENT =  10  deep stalls, where full / almost-full logic breaks
--   READY_PERCENT =   0  permanent stall: the DUT must emit nothing and lose
--                        nothing
--
-- uniform() is deterministic for a given seed pair. That matters more than
-- the quality of the randomness: a stalled run that fails must be replayable
-- exactly, so the seeds are generics (SEED1, SEED2) with fixed defaults.

library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

entity axis_stall is
    generic (
        READY_PERCENT : integer range 0 to 100 := 100;
        SEED1         : positive := 1;
        SEED2         : positive := 7
    );
    port (
        clk, rstn : in  std_logic;
        tready    : out std_logic
    );
end axis_stall;


architecture sim of axis_stall is
begin

    stall_proc: process

        variable s1 : positive := SEED1;
        variable s2 : positive := SEED2;
        variable r  : real;

    begin
        tready <= '0';

        if(rstn /= '1') then
            wait until rstn = '1';
        end if;

        loop
            wait until rising_edge(clk);
            uniform(s1, s2, r);                     -- r in [0.0, 1.0)
            if(r * 100.0 < real(READY_PERCENT)) then
                tready <= '1';
            else
                tready <= '0';
            end if;
        end loop;
    end process;

end sim;
