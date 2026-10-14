-- Written by Yuval Peleg & Aylon Feraru Jun.2026
-- Extracts useful data from the UDP header and sends the payload to the next block
-- ATTENTION: checksum isn't checked

-- =========================================================================
-- UDP Packet Structure (Granular Bit-Level View)
-- =========================================================================
-- +-----------------------+---------+-------------------------------------+
-- | Field Name            | Size    | Description                         |
-- +-----------------------+---------+-------------------------------------+
-- | Source Port           | 16 bits | Sender's application port           |
-- | Destination Port      | 16 bits | Receiver's application port         |
-- | UDP Length            | 16 bits | Length of UDP Header + Payload      |
-- | UDP Checksum          | 16 bits | Error detection for UDP segment     |
-- | Payload (Data)        | Variable| Application layer data              |
-- +-----------------------+---------+-------------------------------------+
-- | Total Minimum Size    | 8 b     | (UDP Header only)                   |
-- | Total Maximum Size    | 65535 b | (Limited by IP MTU/Fragmentation)   |
-- =========================================================================


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_udp is
    port (
        clk, rstn : in std_logic;

        -- Input AXIS
        s_axis_tdata  : in std_logic_vector(63 downto 0);
        s_axis_tkeep  : in std_logic_vector(7 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast  : in std_logic;
        s_axis_tuser  : in std_logic;

        -- Output AXIS (transmits payload, no headers)
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tuser  : out std_logic;

        src_port : out std_logic_vector(15 downto 0);
        dst_port : out std_logic_vector(15 downto 0)
    );
end rx_udp;

architecture rtl of rx_udp is

    -----------------------------------------------------------------
    -- internal signals
    -----------------------------------------------------------------
    signal total_len_buffer : unsigned(15 downto 0) := (others => '0');

    -----------------------------------------------------------------
    -- state machine
    -----------------------------------------------------------------
    type state_type is (header, payload, dump);
    signal state : state_type := header;

begin

    process(clk, rstn)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                m_axis_tdata  <= (others => '0');
                m_axis_tkeep  <= (others => '0');
                m_axis_tvalid <= '0';
                m_axis_tlast  <= '0';
                m_axis_tuser  <= '0';

                src_port <= (others => '0');
                dst_port <= (others => '0');
                
                state <= header;
            else
                case state is

                    when header =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= (others => '0');
                        m_axis_tvalid <= '0';
                        m_axis_tlast  <= '0';
                        m_axis_tuser  <= '0';

                        if(s_axis_tvalid = '1') then
                            -- checking if the packet is empty header or mismatching length
                            if(unsigned(s_axis_tdata(31 downto 16)) > 8 and s_axis_tlast /= '1') then
                                src_port <= s_axis_tdata(63 downto 48);
                                dst_port <= s_axis_tdata(47 downto 32);
                                total_len_buffer <= unsigned(s_axis_tdata(31 downto 16))-8; -- minus 8 because we omit the header
                                state <= payload;
                            else
                                -- mismatching length
                                if(s_axis_tlast /= '1') then
                                    state <= dump;
                                end if;
                            end if;
                        end if;


                    when payload =>
                        if(s_axis_tvalid = '1') then
                            total_len_buffer <= total_len_buffer - 8;
                            m_axis_tdata     <= s_axis_tdata;
                            m_axis_tkeep     <= s_axis_tkeep;
                            m_axis_tvalid    <= '1';

                            if(total_len_buffer <= 8) then
                                if(total_len_buffer < 8) then
                                    m_axis_tkeep(7 downto 8-to_integer(total_len_buffer)) <= (others => '1');
                                    m_axis_tkeep(7-to_integer(total_len_buffer) downto 0) <= (others => '0');
                                end if;
                                m_axis_tlast <= '1';

                                if(s_axis_tlast = '1') then
                                    state        <= header;
                                    m_axis_tuser <= s_axis_tuser;
                                else
                                    state <= dump;
                                end if;
                            -- length not matching packet size (invalid packet)
                            elsif(s_axis_tlast = '1') then
                                state <= header;
                                m_axis_tlast <= '1';
                                m_axis_tuser <= '1';
                            end if;
                        else
                            m_axis_tvalid <= '0';
                        end if;
                        

                    when dump =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= (others => '0');
                        m_axis_tvalid <= '0';
                        m_axis_tlast  <= '0';
                        
                        if(s_axis_tvalid = '1' and s_axis_tlast = '1') then
                            state <= header;
                        end if;
                        
                end case;
            end if;
        end if;
    end process;

end architecture;