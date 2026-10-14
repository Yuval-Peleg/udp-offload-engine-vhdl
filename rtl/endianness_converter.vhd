-- Written by Yuval Peleg & Aylon Feraru  Jun.2026
-- Converts an 8 byte vector from big to little endian and vice versa

library ieee;
use ieee.std_logic_1164.all;


entity endianness_converter is
    port (
        tdata_in  : in std_logic_vector(63 downto 0);
        tkeep_in  : in std_logic_vector(7 downto 0);
        tdata_out : out std_logic_vector(63 downto 0);
        tkeep_out : out std_logic_vector(7 downto 0)
    );
end endianness_converter;

architecture Behavioral of endianness_converter is
begin

    tdata_out(63 downto 56) <= tdata_in(7 downto 0);
    tdata_out(55 downto 48) <= tdata_in(15 downto 8);
    tdata_out(47 downto 40) <= tdata_in(23 downto 16);
    tdata_out(39 downto 32) <= tdata_in(31 downto 24);
    tdata_out(31 downto 24) <= tdata_in(39 downto 32);
    tdata_out(23 downto 16) <= tdata_in(47 downto 40);
    tdata_out(15 downto 8)  <= tdata_in(55 downto 48);
    tdata_out(7 downto 0)   <= tdata_in(63 downto 56);

    tkeep_out(7) <= tkeep_in(0);
    tkeep_out(6) <= tkeep_in(1);
    tkeep_out(5) <= tkeep_in(2);
    tkeep_out(4) <= tkeep_in(3);
    tkeep_out(3) <= tkeep_in(4);
    tkeep_out(2) <= tkeep_in(5);
    tkeep_out(1) <= tkeep_in(6);
    tkeep_out(0) <= tkeep_in(7);

end Behavioral;