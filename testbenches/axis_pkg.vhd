-- Shared types and helpers for the AXI-Stream verification components
-- (axis_driver, axis_monitor, axis_checker, axis_stall).
--
-- Every AXIS interface in rtl/ is 64-bit tdata / 8-bit tkeep, so nothing here
-- is parameterized by width. See testbenches/README.md.

library ieee;
use ieee.std_logic_1164.all;

package axis_pkg is

    -----------------------------------------------------------------
    -- types
    -----------------------------------------------------------------
    -- The master -> slave half of an AXI-Stream interface. tready flows the
    -- other way and cannot live in the same record: record elements have no
    -- direction of their own before VHDL-2019, so a mixed-direction record
    -- can never be a port.
    type axis_beat_t is record
        tdata  : std_logic_vector(63 downto 0);
        tkeep  : std_logic_vector(7 downto 0);
        tvalid : std_logic;
        tlast  : std_logic;
        -- Packet-level error flag, asserted WITH tlast to mark the packet
        -- just delivered as invalid. Blocks with no tuser tie it to '0'.
        tuser  : std_logic;
    end record;

    constant AXIS_IDLE : axis_beat_t := (
        tdata  => (others => '0'),
        tkeep  => (others => '0'),
        tvalid => '0',
        tlast  => '0',
        tuser  => '0'
    );

    -----------------------------------------------------------------
    -- helpers
    -----------------------------------------------------------------
    -- Bytes are packed MSB-first: byte 0 is tdata(63 downto 56) and tkeep(7).
    -- A valid tkeep is therefore a run of '1's starting at bit 7 with nothing
    -- after the first '0'.
    function keep_is_contiguous(tkeep : std_logic_vector) return boolean;

    -----------------------------------------------------------------
    -- test-case labelling
    -----------------------------------------------------------------
    -- A human-readable name for the packet currently being driven, so a
    -- waveform reads "wrong dst port" instead of only hex. The width is fixed
    -- because a VHDL signal cannot be an unconstrained string.
    constant CASE_NAME_LEN : positive := 48;
    subtype case_name_t is string(1 to CASE_NAME_LEN);
    constant CASE_NAME_BLANK : case_name_t := (others => ' ');

    -- left-justify into the fixed width: trim leading blanks, pad or truncate
    function to_case_name(s : string) return case_name_t;

end package;


package body axis_pkg is

    function keep_is_contiguous(tkeep : std_logic_vector) return boolean is
        variable seen_gap : boolean := false;
    begin
        for i in tkeep'high downto tkeep'low loop
            if(tkeep(i) = '0') then
                seen_gap := true;
            elsif(seen_gap) then
                return false;               -- a kept byte after a hole
            end if;
        end loop;
        return true;
    end function;


    function to_case_name(s : string) return case_name_t is
        variable r     : case_name_t := (others => ' ');
        variable first : integer     := s'high + 1;   -- past the end if all blank
        variable j     : positive    := 1;
    begin
        for i in s'range loop
            if(s(i) /= ' ') then
                first := i;
                exit;
            end if;
        end loop;

        for i in first to s'high loop
            exit when j > CASE_NAME_LEN;
            r(j) := s(i);
            j := j + 1;
        end loop;
        return r;
    end function;

end package body;
