-- Written by Yuval Peleg & Aylon Feraru  Jun.2026
-- Filters relevant ARP packets and returns valid ones with dst MAC

-- ===========================================================================
-- Ethernet II Frame Format
-- ===========================================================================
-- +-----------------+-----------+---------------------------------+
-- | Field Name      | Size      | Function                        |
-- +-----------------+-----------+---------------------------------+
-- | Destination MAC | 6 bytes   | Recipient ID                    |
-- | Source MAC      | 6 bytes   | Sender ID                       |
-- | EtherType       | 2 bytes   | Must be 0x0806                  |
-- | ARP Message     | 28 bytes  |                                 |
-- | Padding         | 18 bytes  | Ethernet Packet min len 60bytes |
-- +-----------------+-----------+---------------------------------+
-- ===========================================================================
-- ARP Packet Structure (Address Resolution Protocol)
-- Standard Size for Ethernet/IPv4: 28 Bytes
-- ===========================================================================
-- +-------------------------+----------+------------------------------------+
-- | Field Name              | Size     | Description                        |
-- +-------------------------+----------+------------------------------------+
-- | Hardware Type (HTYPE)   | 2 bytes  | e.g., Ethernet (1)                 |
-- | Protocol Type (PTYPE)   | 2 bytes  | e.g., IPv4 (0x0800)                |
-- | Hardware Addr Length    | 1 byte   | Length of MAC (6 bytes)            |
-- | Protocol Addr Length    | 1 byte   | Length of IP  (4 bytes)            |
-- | Operation (OPER)        | 2 bytes  | 1=Request, 2=Reply                 |
-- | Sender Hardware Addr    | 6 bytes  | Sender's MAC Address               |
-- | Sender Protocol Addr    | 4 bytes  | Sender's IP Address                |
-- | Target Hardware Addr    | 6 bytes  | Target's MAC Address (0x0 for Req) |
-- | Target Protocol Addr    | 4 bytes  | Target's IP Address                |
-- +-------------------------+----------+------------------------------------+
-- | Total ARP Packet Size   | 28 bytes | (Does not include Ethernet Header) |
-- +-------------------------+----------+------------------------------------+


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity arp_handler is
    port (
        clk, rstn : in std_logic;
        
        -- ARP in
        s_axis_tdata  : in std_logic_vector(63 downto 0);
        s_axis_tkeep  : in std_logic_vector(7 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast  : in std_logic;

        -- ARP out
        m_axis_tdata   : out std_logic_vector(63 downto 0);
        m_axis_tkeep   : out std_logic_vector(7 downto 0);
        m_axis_tvalid  : out std_logic;
        m_axis_tlast   : out std_logic;
        prog_full_flag : in std_logic;

        -- configs
        conf_mac : in std_logic_vector(47 downto 0);
        conf_ip  : in std_logic_vector(31 downto 0)
    );
end arp_handler;


architecture rtl of arp_handler is

    -----------------------------------------------------------------
    -- constants
    -----------------------------------------------------------------
    -- eth
    constant ETHERTYPE_ARP  : std_logic_vector(15 downto 0) := x"0806";
    constant BROADCAST_MAC  : std_logic_vector(47 downto 0) := x"ffffffffffff";

    -- ARP
    constant HTYPE_ETHERNET : std_logic_vector(15 downto 0) := x"0001"; -- hardware type
    constant PTYPE_IPV4     : std_logic_vector(15 downto 0) := x"0800"; -- protocol type
    constant HADDR_LEN      : std_logic_vector(7 downto 0)  := x"06";   -- hardware address (MAC) length
    constant PADDR_LEN      : std_logic_vector(7 downto 0)  := x"04";   -- protocol address (IPv4) length
    constant OPER_REQ       : std_logic_vector(15 downto 0) := x"0001"; -- operation code (1 - ARP request, 2 - ARP reply)
    constant OPER_REP       : std_logic_vector(15 downto 0) := x"0002";


    -----------------------------------------------------------------
    -- internal signals
    -----------------------------------------------------------------
    signal eth_src_mac       : std_logic_vector(47 downto 0) := (others => '0');
    signal arp_received_ip   : std_logic_vector(31 downto 0) := (others => '0');

    signal reply_eth         : std_logic_vector(47 downto 0) := (others => '0');
    signal reply_ip          : std_logic_vector(31 downto 0) := (others => '0');
    signal valid_packet_flag : std_logic := '0';

    -----------------------------------------------------------------
    -- state machine
    -----------------------------------------------------------------
    type rx_state_type is (eth0, eth1, arp0, arp1, arp2, arp3, dump);
    signal rx_state : rx_state_type := eth0;

    type tx_state_type is (eth0, eth1, arp0, arp1, arp2, arp3, padding0, padding1);
    signal tx_state : tx_state_type := eth0;
    
    
begin

    receiving_data : process(clk, rstn)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                valid_packet_flag <= '0';
                rx_state <= eth0;

                eth_src_mac     <= (others => '0');
                arp_received_ip <= (others => '0');

                reply_eth <= (others => '0');
                reply_ip  <= (others => '0');
        
            else
                valid_packet_flag <= '0';

                if(s_axis_tvalid = '1') then
                    case rx_state is

                        when eth0 =>
                            if((s_axis_tdata(63 downto 16) = BROADCAST_MAC or s_axis_tdata(63 downto 16) = conf_mac) and s_axis_tlast = '0') then
                                eth_src_mac(47 downto 32) <= s_axis_tdata(15 downto 0);
                                rx_state <= eth1;
                            else
                                if(s_axis_tlast /= '1') then
                                    rx_state <= dump;
                                end if;
                            end if;

                        when eth1 =>
                            if(s_axis_tdata(31 downto 16) = ETHERTYPE_ARP and 
                               s_axis_tdata(15 downto 0) = HTYPE_ETHERNET and
                               s_axis_tlast = '0') then

                                eth_src_mac(31 downto 0) <= s_axis_tdata(63 downto 32);
                                rx_state <= arp0;
                            else
                                if(s_axis_tlast = '1') then
                                    rx_state <= eth0;
                                else
                                    rx_state <= dump;
                                end if;
                            end if;
                    
                        when arp0 =>
                            if(s_axis_tdata(63 downto 48) = PTYPE_IPV4                and
                               s_axis_tdata(47 downto 40) = HADDR_LEN                 and
                               s_axis_tdata(39 downto 32) = PADDR_LEN                 and
                               s_axis_tdata(31 downto 16) = OPER_REQ                  and
                               s_axis_tdata(15 downto 0)  = eth_src_mac(47 downto 32) and
                               s_axis_tlast = '0') then
                        
                                rx_state <= arp1;
                            else
                                if(s_axis_tlast = '1') then
                                    rx_state <= eth0;
                                else
                                    rx_state <= dump;
                                end if;
                            end if;

                        when arp1 =>
                            if(s_axis_tdata(63 downto 32) = eth_src_mac(31 downto 0) and s_axis_tlast = '0') then
                                arp_received_ip <= s_axis_tdata(31 downto 0);
                                rx_state <= arp2;
                            else
                                if(s_axis_tlast = '1') then
                                    rx_state <= eth0;
                                else
                                    rx_state <= dump;
                                end if;
                            end if;

                        when arp2 =>
                            if(s_axis_tdata(15 downto 0) = conf_ip(31 downto 16) and s_axis_tlast = '0') then
                                rx_state <= arp3;
                            else
                                if(s_axis_tlast = '1') then
                                    rx_state <= eth0;
                                else
                                    rx_state <= dump;
                                end if;
                            end if;

                        when arp3 =>
                            -- commit send point
                            if(s_axis_tdata(63 downto 48) = conf_ip(15 downto 0) and prog_full_flag = '0') then
                                reply_eth         <= eth_src_mac;
                                reply_ip          <= arp_received_ip;
                                valid_packet_flag <= '1';
                            end if;

                            if(s_axis_tlast = '1') then
                                rx_state <= eth0;
                            else
                                -- removes padding if needed
                                rx_state <= dump;
                            end if;
                        

                        when dump =>
                            if(s_axis_tlast = '1') then
                                rx_state <= eth0;
                            end if;

                    end case;
                end if;
            end if;
        end if;
    end process;


    sending_reply : process(clk, rstn) is
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                m_axis_tdata  <= (others => '0');
                m_axis_tkeep  <= (others => '0');
                m_axis_tvalid <= '0';
                m_axis_tlast  <= '0';

                tx_state <= eth0;

            else
                case tx_state is

                    when eth0 =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= (others => '0');
                        m_axis_tvalid <= '0';
                        m_axis_tlast  <= '0';

                        if(valid_packet_flag = '1') then
                            m_axis_tdata  <= reply_eth & conf_mac(47 downto 32);
                            m_axis_tkeep  <= x"ff";
                            m_axis_tvalid <= '1';
                            m_axis_tlast  <= '0';

                            tx_state <= eth1;
                        end if;

                    when eth1 =>
                        m_axis_tdata  <= conf_mac(31 downto 0) & ETHERTYPE_ARP & HTYPE_ETHERNET;
                        m_axis_tkeep  <= x"ff";
                        m_axis_tvalid <= '1';
                        m_axis_tlast  <= '0';

                        tx_state <= arp0;
                
                    when arp0 =>
                        m_axis_tdata  <= PTYPE_IPV4 & HADDR_LEN & PADDR_LEN & OPER_REP & conf_mac(47 downto 32);
                        m_axis_tkeep  <= x"ff";
                        m_axis_tvalid <= '1';
                        m_axis_tlast  <= '0';

                        tx_state <= arp1;

                    when arp1 =>
                        m_axis_tdata  <= conf_mac(31 downto 0) & conf_ip;
                        m_axis_tkeep  <= x"ff";
                        m_axis_tvalid <= '1';
                        m_axis_tlast  <= '0';

                        tx_state <= arp2;

                    when arp2 =>
                        m_axis_tdata  <= reply_eth & reply_ip(31 downto 16);
                        m_axis_tkeep  <= x"ff";
                        m_axis_tvalid <= '1';
                        m_axis_tlast  <= '0';

                        tx_state <= arp3;

                    when arp3 =>
                        m_axis_tdata  <= reply_ip(15 downto 0) & (47 downto 0 => '0');
                        m_axis_tkeep  <= x"ff";
                        m_axis_tvalid <= '1';
                        m_axis_tlast  <= '0'; 

                        tx_state <= padding0;

                    when padding0 =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= x"ff";
                        m_axis_tvalid <= '1';
                        m_axis_tlast  <= '0'; 

                        tx_state <= padding1;

                    when padding1 =>
                        m_axis_tdata  <= (others => '0');
                        m_axis_tkeep  <= x"f0";
                        m_axis_tvalid <= '1';
                        m_axis_tlast  <= '1'; 

                        tx_state <= eth0;
                    

                end case;
            end if;
        end if;
    end process;

end architecture;