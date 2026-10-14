-- Written by Yuval Peleg & Aylon Feraru Jun.2026
-- Extracts useful data from the IPv4 header and sends the payload to the next block

-- ============================================================================
-- IPv4 Packet Structure (Granular Bit-Level View)
-- ============================================================================
-- +-----------------------+---------+----------------------------------------+
-- | Field Name            | Size    | Description                            |
-- +-----------------------+---------+----------------------------------------+
-- | Version               | 4 bits  | IP Version (typically 4)               | checked
-- | IHL (Header Length)   | 4 bits  | Header size in 32-bit words            | checked
-- | DSCP                  | 6 bits  | Differentiated Services Code Point     | not checked
-- | ECN                   | 2 bits  | Explicit Congestion Notification       | not checked
-- | Total Length          | 16 bits | Entire packet size (Header + Payload)  | saved
-- | Identification        | 16 bits | Fragmentation ID                       | not checked
-- | Flags                 | 3 bits  | Reserved, DF, and MF flags             | checked
-- | Fragment Offset       | 13 bits | Position of fragment in original stream| checked
-- | TTL (Time to Live)    | 8 bits  | Hop limit to prevent infinite looping  | checked
-- | Protocol              | 8 bits  | L4 Protocol (e.g., 0x06=TCP, 0x11=UDP) | checked
-- | Header Checksum       | 16 bits | Error detection for the IP header      | checked
-- | Source IP Address     | 32 bits | Sender's IPv4 address                  | saved
-- | Destination IP Address| 32 bits | Receiver's IPv4 address                | checked
-- | Payload               | Variable| Layer 4 Data (TCP/UDP/ICMP/etc.)       |
-- +-----------------------+---------+----------------------------------------+
-- | Total Minimum Size    | 20 b    | (Standard header without options)      |
-- | Total Maximum Size    | 65535 b | (Maximum theoretical IP packet size)   |
-- ============================================================================


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_ipv4 is
    port (
        clk, rstn : in std_logic;

        -- Input AXIS
        s_axis_tdata  : in std_logic_vector(63 downto 0);
        s_axis_tkeep  : in std_logic_vector(7 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast  : in std_logic;

        -- Output AXIS (transmits payload, no headers)
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tuser  : out std_logic;

        conf_ip : in std_logic_vector (31 downto 0); 

        src_ip : out std_logic_vector(31 downto 0)

    );
end rx_ipv4;

architecture rtl of rx_ipv4 is

    -----------------------------------------------------------------
    -- constants
    -----------------------------------------------------------------
    constant IP_VERSION_4 : std_logic_vector(3 downto 0)  := x"4";
    constant HEADER_LEN   : std_logic_vector(3 downto 0)  := "0101"; -- this number is multiplied by 4 to give the length of the header in bytes
    constant MF_FLAG      : std_logic                     := '0';
    constant VALID_OFFSET : std_logic_vector(12 downto 0) := (others => '0');
    constant PROTOCOL_UDP : std_logic_vector(7 downto 0)  := x"11";
    constant BAD_TTL      : std_logic_vector(7 downto 0)  := x"00";

    -----------------------------------------------------------------
    -- internal signals
    -----------------------------------------------------------------
    signal total_len_buffer : unsigned(15 downto 0)        := (others => '0');
    signal checksum         : unsigned(19 downto 0)        := (others => '0');
    
    signal payload_tdata_buffer : std_logic_vector(31 downto 0) := (others => '0');
    signal payload_tkeep_buffer : std_logic_vector(3 downto 0)  := (others => '0');

    -----------------------------------------------------------------
    -- state machine
    -----------------------------------------------------------------
    type state_type is (header, payload, dump);
    signal state : state_type := header;

    signal header_word_count : integer range 0 to 2 := 0;

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

                src_ip <= (others => '0');
            
                payload_tkeep_buffer <= (others => '0');
                payload_tdata_buffer <= (others => '0');
            
                state <= header;
                header_word_count <= 0;

            else
                case state is

                    when header =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= (others => '0');
                        m_axis_tvalid <= '0';
                        m_axis_tlast  <= '0';
                        m_axis_tuser  <= '0';

                        -- outputting extra beat from last packet if there is one
                        if(payload_tkeep_buffer /= "0000") then
                            m_axis_tdata  <= payload_tdata_buffer & x"00000000";
                            m_axis_tkeep  <= payload_tkeep_buffer & "0000";
                            m_axis_tvalid <= '1';
                            m_axis_tlast  <= '1';
                        end if;

                        payload_tdata_buffer <= (others => '0');
                        payload_tkeep_buffer <= (others => '0');

                        if(s_axis_tvalid = '1') then
                            header_word_count <= 0;

                            case header_word_count is

                                when 0 =>                                 
                                    if (s_axis_tlast              /= '1'          and
                                        s_axis_tdata(63 downto 60) = IP_VERSION_4 and
                                        s_axis_tdata(59 downto 56) = HEADER_LEN   and 
                                        s_axis_tdata(13)           = MF_FLAG      and
                                        s_axis_tdata(12 downto 0)  = VALID_OFFSET and
                                        unsigned(s_axis_tdata(47 downto 32)) > 20
                                        ) then 

                                        checksum <= to_unsigned(to_integer(unsigned(s_axis_tdata(63 downto 48))) + to_integer(unsigned(s_axis_tdata(47 downto 32))) + to_integer(unsigned(s_axis_tdata(31 downto 16))) + to_integer(unsigned(s_axis_tdata(15 downto 0))), 20);
                                        total_len_buffer <= unsigned(s_axis_tdata (47 downto 32));

                                        header_word_count <= header_word_count + 1;
                                    else
                                        -- need to keep flushing invalid packet
                                        if(s_axis_tlast /= '1') then
                                            state <= dump;
                                        end if;
                                    end if;
                                
                                when 1 =>
                                    if (s_axis_tlast               /= '1'     and
                                        s_axis_tdata(63 downto 56) /= BAD_TTL and 
                                        s_axis_tdata(55 downto 48)  = PROTOCOL_UDP
                                        ) then 
                                        checksum <= checksum + to_unsigned(to_integer(unsigned(s_axis_tdata(63 downto 48))) + to_integer(unsigned(s_axis_tdata(47 downto 32))) + to_integer(unsigned(s_axis_tdata(31 downto 16))) + to_integer(unsigned(s_axis_tdata(15 downto 0))), 20);

                                        src_ip <= s_axis_tdata(31 downto 0);

                                        header_word_count <= header_word_count + 1;
                                    else 
                                        -- need to keep flushing invalid packet
                                        if(s_axis_tlast /= '1') then
                                            state <= dump;
                                        end if;
                                    end if;

                                when 2 =>
                                    if (s_axis_tlast /= '1' and s_axis_tdata(63 downto 32) = conf_ip) then
                                        checksum <= checksum + to_unsigned(to_integer(unsigned(s_axis_tdata(63 downto 48))) + to_integer(unsigned(s_axis_tdata(47 downto 32))), 20);

                                        payload_tdata_buffer <= s_axis_tdata(31 downto 0);
                                        total_len_buffer     <= total_len_buffer - 20;

                                        state <= payload;
                                    else 
                                        -- need to keep flushing invalid packet
                                        if(s_axis_tlast /= '1') then
                                            state <= dump;
                                        end if;
                                    end if;

                            end case;
                        end if;


                    when payload =>
                        if(s_axis_tvalid = '1' and (checksum(15 downto 0) + checksum(19 downto 16)) = x"FFFF") then
                            total_len_buffer <= total_len_buffer - 8;

                            m_axis_tdata  <= payload_tdata_buffer & s_axis_tdata(63 downto 32);
                            payload_tdata_buffer <= s_axis_tdata(31 downto 0);
                            m_axis_tkeep  <= x"FF"; 
                            m_axis_tvalid <= '1';

                            -- next beat is last and has 4 or less bytes
                            if(total_len_buffer > 8 and total_len_buffer <= 12) then
                                payload_tkeep_buffer(3 downto 4-to_integer(total_len_buffer - 8)) <= (others => '1');
                                payload_tkeep_buffer(3-to_integer(total_len_buffer - 8) downto 0) <= (others => '0');
                                state <= header;
                            -- this beat is last and has more than 4 bytes
                            elsif(total_len_buffer <= 8) then
                                if(total_len_buffer < 8) then
                                    m_axis_tkeep(7 downto 8-to_integer(total_len_buffer)) <= (others => '1');
                                    m_axis_tkeep(7-to_integer(total_len_buffer) downto 0) <= (others => '0');
                                end if;
                                m_axis_tlast <= '1';

                                -- no padding to get rid of
                                if(s_axis_tlast = '1') then
                                    state <= header;
                                -- there's padding left to this packet
                                else
                                    state <= dump;
                                end if;
                            elsif(s_axis_tlast = '1') then
                                state <= header;
                                m_axis_tlast <= '1';
                                m_axis_tuser <= '1';
                            end if;
                        -- packet coming in but checksum isn't valid
                        elsif(s_axis_tvalid = '1') then
                            state <= dump;
                        else
                            m_axis_tdata  <= (others => '0');
                            m_axis_tkeep  <= (others => '0');
                            m_axis_tvalid <= '0';
                            m_axis_tlast  <= '0';
                            m_axis_tuser  <= '0';
                        end if;
                    

                    when dump =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= (others => '0');
                        m_axis_tvalid <= '0';
                        m_axis_tlast  <= '0';
                        m_axis_tuser  <= '0';
                    
                        if(s_axis_tvalid = '1' and s_axis_tlast = '1') then
                            state <= header;
                        end if;
                    
                end case;
            end if;
        end if;
    end process;

end architecture;