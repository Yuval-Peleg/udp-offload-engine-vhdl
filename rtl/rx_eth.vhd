-- Written by Yuval Peleg & Aylon Feraru Jun.2026
-- Extracts useful data from the Ethernet header and sends the payload to the next block

-- ===========================================================================
-- Ethernet II Frame Format (Used for IPv4)
-- ===========================================================================
-- +-----------------+-----------+--------------------------------+
-- | Field Name      | Size      | Function                       |
-- +-----------------+-----------+--------------------------------+
-- | Destination MAC | 6 bytes   | Recipient ID                   |
-- | Source MAC      | 6 bytes   | Sender ID                      |
-- | EtherType       | 2 bytes   | Must be 0x0800 (for IPv4)      |
-- | Payload         | Variable  | Contains the IPv4 Packet       |
-- | Padding         | Variable  | Handled by IPv4 block          |
-- +-----------------+-----------+--------------------------------+
--
-- Note: Payload length is determined by the 'Total Length' field 
--       inside the encapsulated IPv4 header.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_eth is
    port (
        clk, rstn : in std_logic;
        
        -- Ethernet Input AXIS
        s_axis_tdata  : in std_logic_vector(63 downto 0);
        s_axis_tkeep  : in std_logic_vector(7 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast  : in std_logic;

        -- IPv4 Output AXIS
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;

        -- configs
        conf_mac : in std_logic_vector(47 downto 0);

        -- retrieved data
        src_mac : out std_logic_vector(47 downto 0)
    );
end rx_eth;

architecture rtl of rx_eth is

    constant ETHERTYPE_IPV4 : std_logic_vector(15 downto 0) := x"0800";

    type state_type is (header, payload, dump);
    signal state : state_type := header;

    signal header_word_count : integer range 0 to 1 := 0;
    signal dst_mac_buffer    : std_logic_vector(47 downto 0) := (others => '0');

    signal src_mac_buffer : std_logic_vector(15 downto 0) := (others => '0');

    signal payload_tdata_buffer : std_logic_vector(15 downto 0) := (others => '0');
    signal payload_tkeep_buffer : std_logic_vector(1 downto 0)  := (others => '0');

begin

    process(clk, rstn)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                state <= header;
            
                m_axis_tdata  <= (others => '0');
                m_axis_tkeep  <= (others => '0');
                m_axis_tvalid <= '0';
                m_axis_tlast  <= '0';

                header_word_count <= 0;
                dst_mac_buffer    <= (others => '0');
                src_mac_buffer    <= (others => '0');

                payload_tdata_buffer <= (others => '0');
                payload_tkeep_buffer <= (others => '0');
            
                src_mac <= (others => '0');


            else
                case state is

                    when header =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= (others => '0');
                        m_axis_tvalid <= '0';
                        m_axis_tlast  <= '0';

                        -- outputting extra beat from last packet if there is one
                        if(payload_tkeep_buffer /= "00") then
                            m_axis_tdata  <= payload_tdata_buffer & x"000000000000";
                            m_axis_tkeep  <= payload_tkeep_buffer & "000000";
                            m_axis_tvalid <= '1';
                            m_axis_tlast  <= '1';
                        end if;

                        payload_tdata_buffer <= (others => '0');
                        payload_tkeep_buffer <= (others => '0');

                        if(s_axis_tvalid = '1' and s_axis_tlast /= '1') then
                            header_word_count <= 0;

                            case header_word_count is

                                -- dst MAC & start of src MAC
                                when 0 => 
                                    dst_mac_buffer <= s_axis_tdata(63 downto 16);
                                    src_mac_buffer <= s_axis_tdata(15 downto 0);

                                    header_word_count <= header_word_count + 1;

                                -- end of src MAC & Ethertype & start of payload
                                when 1 => 
                                    if(dst_mac_buffer = conf_mac and s_axis_tdata(31 downto 16) = ETHERTYPE_IPV4) then -- dst MAC is ours and ethertype is IPv4
                                        src_mac              <= src_mac_buffer & s_axis_tdata(63 downto 32);
                                        payload_tdata_buffer <= s_axis_tdata(15 downto 0);

                                        state <= payload;
                                    else
                                        if(s_axis_tlast /= '1') then
                                            state <= dump;
                                        end if;
                                    end if;
                            end case;
                        elsif(s_axis_tlast = '1') then
                            header_word_count <= 0;
                        end if;


                    when payload =>
                        if(s_axis_tvalid = '1') then
                            m_axis_tdata         <= payload_tdata_buffer & s_axis_tdata(63 downto 16);
                            payload_tdata_buffer <= s_axis_tdata(15 downto 0);
                            m_axis_tkeep         <= x"FF";
                            m_axis_tvalid        <= '1';

                            if(s_axis_tlast = '1') then
                                if(s_axis_tkeep(1 downto 0) = "00") then -- last word has space for the two extra bytes from the start of the payload
                                    m_axis_tkeep <= "11" & s_axis_tkeep(7 downto 2); -- shifting tkeep twice to the right and adding one's to the first two bits 
                                    m_axis_tlast <= '1';
                                elsif(s_axis_tkeep(0) = '0') then -- has space for 1 byte, needs another word
                                    payload_tkeep_buffer <= "10";
                                else                              -- doesn't have space, needs another word 
                                    payload_tkeep_buffer <= "11";
                                end if;

                                state <= header;
                            end if;
                        else
                            m_axis_tdata  <= (others => '0');
                            m_axis_tkeep  <= (others => '0');
                            m_axis_tvalid <= '0';
                            m_axis_tlast  <= '0';
                        end if;
    

                    when dump =>
                        if(s_axis_tvalid = '1' and s_axis_tlast = '1') then
                            state <= header;
                        end if;
                    
                end case;
            end if;
        end if;
    end process;

end architecture;