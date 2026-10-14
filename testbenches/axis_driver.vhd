-- Plays a stimulus file onto an AXI-Stream interface.
--
-- File format, one line per beat (# comments and blank lines are skipped):
--
--     tdata(16 hex)  tkeep(2 hex)  tlast(0|1)  tuser(0|1)  gap(int)
--
-- `gap` is the number of idle cycles to insert BEFORE that beat, which is what
-- makes one set of packets produce the gapless / ipg / random variants.
-- See testbenches/README.md.
--
-- For interfaces without a tready, tie tready to '1': the hold loop then exits
-- on its first iteration, which is one beat per cycle.
--
-- IGNORE_TREADY models a source that cannot be stopped. The XXV Ethernet MAC's
-- receive stream is one: it has no tready at all, so it delivers whether the
-- design is ready or not, and a full buffer downstream loses beats instead of
-- stalling the sender. Driving such a port with the normal hold loop is
-- OPTIMISTIC -- it politely waits, so the testbench never sees the data loss
-- the hardware would produce. With this set, every beat is presented for
-- exactly one cycle and then dropped, tready or no tready.

library ieee;
use ieee.std_logic_1164.all;

use ieee.std_logic_textio.all;
use std.textio.all;

use work.axis_pkg.all;

entity axis_driver is
    generic (
        STIMULUS_FILE : string;
        -- true = a source that cannot be backpressured, e.g. the MAC's rx port
        IGNORE_TREADY : boolean := false;
        -- Idle clocks after reset releases before the first beat. The XPM FIFOs
        -- hold s_axis_tready low for a few more clocks while wr_rst_busy is
        -- set, so a source that IGNORES tready and starts immediately loses its
        -- first frame. On hardware the MAC does not transmit until the link is
        -- up, which is far later, so starting at reset+0 would be testing a
        -- situation that cannot happen.
        START_DELAY : natural := 0
    );
    port (
        clk, rstn : in std_logic;

        axis   : out axis_beat_t;
        tready : in  std_logic;             -- tie to '1' if the interface has none

        -- Which test case is being driven right now. Picked up from
        -- "# CASE <n> <text>" marker lines in the stimulus file, so a waveform
        -- shows "wrong dst port" next to the beats instead of only hex.
        -- Stays 0 / blank for stimulus files that carry no markers.
        case_index : out natural;
        case_name  : out case_name_t;

        done : out std_logic                -- '1' once the file is exhausted
    );
end axis_driver;


architecture sim of axis_driver is

    file stimulus : text open read_mode is STIMULUS_FILE;

begin

    drive_proc: process

        variable row  : line;
        variable rest : line;
        variable beat : axis_beat_t;
        variable gap  : integer;
        variable idx  : integer;
        variable ok   : boolean;

    begin
        axis       <= AXIS_IDLE;
        done       <= '0';
        case_index <= 0;
        case_name  <= CASE_NAME_BLANK;

        if(rstn /= '1') then
            wait until rstn = '1';
        end if;
        wait until rising_edge(clk);
        for i in 1 to START_DELAY loop
            wait until rising_edge(clk);
        end loop;

        while(not endfile(stimulus)) loop
            readline(stimulus, row);

            -- order matters: indexing character 1 of a zero-length line is a
            -- bounds error, not a false
            next when row'length = 0;

            if(row.all(1) = '#') then
                -- "# CASE <n> <description>" labels the packet that follows.
                -- Every other comment is ignored.
                if(row'length >= 8 and row.all(3 to 6) = "CASE") then
                    rest := new string'(row.all(7 to row'length));
                    read(rest, idx, ok);
                    if(ok) then
                        case_index <= idx;
                        case_name  <= to_case_name(rest.all);
                    end if;
                    deallocate(rest);
                end if;
                next;
            end if;

            hread(row, beat.tdata);
            hread(row, beat.tkeep);
            read(row, beat.tlast);
            read(row, beat.tuser);
            read(row, gap);
            beat.tvalid := '1';

            -- idle BEFORE the beat
            axis <= AXIS_IDLE;
            for i in 1 to gap loop
                wait until rising_edge(clk);
            end loop;

            -- present, and hold until the handshake completes.
            -- tvalid must NOT be withdrawn inside this loop -- that is the
            -- protocol violation axis_checker looks for first.
            axis <= beat;
            if(IGNORE_TREADY) then
                -- one cycle, accepted or not. The beat is gone either way,
                -- which is precisely what makes an unstoppable source hard to
                -- receive from.
                wait until rising_edge(clk);
            else
                loop
                    wait until rising_edge(clk);
                    exit when tready = '1';
                end loop;
            end if;
        end loop;

        axis <= AXIS_IDLE;
        done <= '1';
        wait;
    end process;

end sim;
