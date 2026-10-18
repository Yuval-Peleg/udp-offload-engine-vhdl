-- Written by Yuval Peleg & Aylon Feraru Jul.2026
-- Reads data from UDP header, constructs and sends IPv4 header and payload afterwards.

-- ** DOES RELY ON THE PAYLOAD BEING A VALID UDP PACKET **

-- ============================================================================
-- IPv4 Packet Structure (Granular Bit-Level View)
-- ============================================================================
-- +-----------------------+---------+----------------------------------------+
-- | Field Name            | Size    | Description                            |
-- +-----------------------+---------+----------------------------------------+
-- | Version               | 4 bits  | IP Version (typically 4)               | constant
-- | IHL (Header Length)   | 4 bits  | Header size in 32-bit words            | constant
-- | DSCP                  | 6 bits  | Differentiated Services Code Point     | constant
-- | ECN                   | 2 bits  | Explicit Congestion Notification       | constant
-- | Total Length          | 16 bits | Entire packet size (Header + Payload)  | calculated
-- | Identification        | 16 bits | Fragmentation ID                       | running counter
-- | Flags                 | 3 bits  | Reserved, DF, and MF flags             | constant
-- | Fragment Offset       | 13 bits | Position of fragment in original stream| constant
-- | TTL (Time to Live)    | 8 bits  | Hop limit to prevent infinite looping  | constant
-- | Protocol              | 8 bits  | L4 Protocol (e.g., 0x06=TCP, 0x11=UDP) | constant
-- | Header Checksum       | 16 bits | Error detection for the IP header      | calculated
-- | Source IP Address     | 32 bits | Sender's IPv4 address                  | input
-- | Destination IP Address| 32 bits | Receiver's IPv4 address                | input
-- | Payload               | Variable| Layer 4 Data (TCP/UDP/ICMP/etc.)       |
-- +-----------------------+---------+----------------------------------------+
-- | Total Minimum Size    | 20 b    | (Standard header without options)      |
-- | Total Maximum Size    | 65535 b | (Maximum theoretical IP packet size)   |
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- for instantiating Vivado IPs
library xpm;
use xpm.vcomponents.all;

entity tx_ipv4 is
    generic(
        PACKET_FIFO_DEPTH : integer := 16
    );
    port (
        clk, rstn : in std_logic;

        -- Input AXIS
        s_axis_tdata  : in std_logic_vector(63 downto 0);
        s_axis_tkeep  : in std_logic_vector(7 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast  : in std_logic;
        s_axis_tuser  : in std_logic_vector(79 downto 0);
        s_axis_tready : out std_logic;

        -- Output AXIS
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tuser  : out std_logic_vector(47 downto 0);
        m_axis_tready : in std_logic;

        conf_ip : in std_logic_vector (31 downto 0)
    );
end tx_ipv4;

architecture rtl of tx_ipv4 is

    -----------------------------------------------------------------
    -- constants & declarations
    -----------------------------------------------------------------
    constant IPV4_HEADER_LEN : integer := 20;
    constant MIN_UDP_LEN     : integer := 26;

    constant VERSION     : std_logic_vector(3 downto 0)  := x"4";            -- IPv4
    constant IHL         : std_logic_vector(3 downto 0)  := x"5";            -- Header size in 32 bits
    constant DSCP        : std_logic_vector(5 downto 0)  := "000000";        -- traffic class, 0 means "best effort" (doesn't matter in PC-PC communication)
    constant ECN         : std_logic_vector(1 downto 0)  := "00";            -- Explicit Congestion Notification, 0 means not ECN compatible 
    constant FLAGS       : std_logic_vector(2 downto 0)  := "010";           -- Don't fragment
    constant FRAG_OFFSET : std_logic_vector(12 downto 0) := "0000000000000"; -- No fragmentation so no offset
    constant TTL         : std_logic_vector(7 downto 0)  := x"40";           -- Default ttl for linux systems
    constant PROTOCOL    : std_logic_vector(7 downto 0)  := x"11";           -- x"11" = 17 = UDP

    -----------------------------------------------------------------
    -- internal signals
    -----------------------------------------------------------------
    signal id        : integer range 0 to 65535 := 0;

    signal m_axis_tvalid_buffer : std_logic := '0';

    signal checksum  : unsigned(19 downto 0)       := (others => '0');
    signal checksum_folded : unsigned(16 downto 0) := (others => '0');

    signal m_axis_fifo_tdata  : std_logic_vector(63 downto 0) := (others => '0');
    signal m_axis_fifo_tvalid : std_logic := '0';
    signal m_axis_fifo_tlast  : std_logic := '0';
    signal m_axis_fifo_tuser  : std_logic_vector(79 downto 0) := (others => '0');
    signal m_axis_fifo_tready : std_logic := '0';

    signal packet_fifo_tready : std_logic := '0';

    signal payload_buffer : std_logic_vector(31 downto 0) := (others => '0');
    signal payload_left    : integer range 0 to 65535 := 0;

    -----------------------------------------------------------------
    -- state machine
    -----------------------------------------------------------------
    type state_type is (header, payload, extra_word);
    signal state : state_type := header;
    signal header_word_count : integer range 0 to 2 := 0;

begin

    ----------------------------------------------------------------------------
    -- Sending Packets
    ----------------------------------------------------------------------------
    process(clk, rstn) is
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                m_axis_tdata         <= (others => '0');
                m_axis_tkeep         <= (others => '0');
                m_axis_tvalid_buffer <= '0';
                m_axis_tlast         <= '0';

                checksum <= (others => '0');
                id       <= 0;

                packet_fifo_tready <= '0';

                state <= header;

                header_word_count <= 0;

            else
                case state is

                    when header =>
                        if(m_axis_tvalid_buffer = '0' or m_axis_tready = '1') then
                            m_axis_tdata         <= (others => '0');
                            m_axis_tkeep         <= (others => '0');
                            m_axis_tvalid_buffer <= '0';
                            m_axis_tlast         <= '0';

                            -- data available to process
                            if(m_axis_fifo_tvalid = '1') then
                                m_axis_tkeep         <= x"FF";
                                m_axis_tvalid_buffer <= '1';
                                m_axis_tlast         <= '0';
                            
                                header_word_count <= header_word_count + 1;
                                case header_word_count is

                                    when 0 =>
                                        m_axis_tdata <= VERSION & IHL & DSCP & ECN & std_logic_vector(to_unsigned(IPV4_HEADER_LEN, 16) + unsigned(m_axis_fifo_tdata(31 downto 16))) & std_logic_vector(to_unsigned(id, 16)) & FLAGS & FRAG_OFFSET;
                                        m_axis_tuser <= m_axis_fifo_tuser(79 downto 32);

                                        -- clamping payload length to [MIN_UDP_LEN] because padding
                                        -- isn't taken into account in the UDP header's length field
                                        if(to_integer(unsigned(m_axis_fifo_tdata(31 downto 16))) < MIN_UDP_LEN) then
                                            payload_left <= MIN_UDP_LEN;
                                        else
                                            payload_left <= to_integer(unsigned(m_axis_fifo_tdata(31 downto 16)));
                                        end if;

                                        -- summing every 16 bits of the header for checksum calculation
                                        checksum <= to_unsigned(to_integer(unsigned(VERSION & IHL & DSCP & ECN))                                           + 
                                                                to_integer((to_unsigned(IPV4_HEADER_LEN, 16) + unsigned(m_axis_fifo_tdata(31 downto 16)))) + 
                                                                to_integer(to_unsigned(id, 16))                                                            + 
                                                                to_integer(unsigned(FLAGS & FRAG_OFFSET))                                                  + 
                                                                to_integer(unsigned(TTL & PROTOCOL))                                                       +
                                                                to_integer(unsigned(conf_ip(31 downto 16)))                                                +
                                                                to_integer(unsigned(conf_ip(15 downto 0)))                                                 +
                                                                to_integer(unsigned(m_axis_fifo_tuser(31 downto 16)))                                           +
                                                                to_integer(unsigned(m_axis_fifo_tuser(15 downto 0)))
                                                                , 20);

                                        -- running packet numbering, rolls back to zero when it reaches max (16 bits)
                                        if(id = (2**16)-1) then
                                            id <= 0;
                                        else
                                            id <= id + 1;
                                        end if;

                                    when 1 =>
                                        m_axis_tdata <= TTL & PROTOCOL & not(std_logic_vector(checksum_folded(15 downto 0) + checksum_folded(16 downto 16))) & conf_ip;
                                        packet_fifo_tready <= '1';

                                    when 2 =>
                                        -- last part of the header is 32 bit, so filling the rest of the word
                                        -- with the start of the payload and carrying the next to the next word.
                                        m_axis_tdata   <= m_axis_fifo_tuser(31 downto 0) & m_axis_fifo_tdata(63 downto 32);
                                        payload_buffer <= m_axis_fifo_tdata(31 downto 0);
                                        payload_left   <= payload_left - 4;

                                        header_word_count <= 0;
                                        state             <= payload;

                                end case;
                            end if;
                        end if;


                    when payload =>
                        if(m_axis_fifo_tvalid = '1' and m_axis_tready = '1') then
                            m_axis_tdata         <= payload_buffer & m_axis_fifo_tdata(63 downto 32);
                            m_axis_tkeep         <= x"FF";
                            m_axis_tvalid_buffer <= '1';
                            m_axis_tlast         <= '0';

                            payload_buffer <= m_axis_fifo_tdata(31 downto 0);
                            payload_left   <= payload_left - 8;

                            if(m_axis_fifo_tlast = '1') then
                                packet_fifo_tready <= '0';

                                -- can fit in current word
                                if(payload_left <= 8) then
                                    -- less than full word
                                    if(payload_left < 8) then
                                        m_axis_tkeep(7 downto 8-payload_left) <= (others => '1');
                                        m_axis_tkeep(7-payload_left downto 0) <= (others => '0');
                                    end if;

                                    m_axis_tlast   <= '1';
                                    state <= header;
                                else
                                    state <= extra_word;
                                end if;
                            end if;
                        end if;


                    when extra_word =>
                        if(m_axis_tready = '1') then
                            m_axis_tdata                          <= payload_buffer & m_axis_fifo_tdata(63 downto 32);
                            m_axis_tkeep                          <= (others => '0');
                            m_axis_tkeep(7 downto 8-payload_left) <= (others => '1');
                            m_axis_tvalid_buffer                  <= '1';
                            m_axis_tlast                          <= '1';

                            state <= header;
                        end if;

                end case;

            end if;
        end if;
    end process;
    m_axis_tvalid <= m_axis_tvalid_buffer;
    -- outside of process to not add clock to calculation
    checksum_folded <= to_unsigned(to_integer(checksum(15 downto 0)) + to_integer(checksum(19 downto 16)), 17);             

    ----------------------------------------------------------------------------
    -- Storage: AXIS FIFO
    ----------------------------------------------------------------------------
    packet_fifo_inst : xpm_fifo_axis
        generic map(
            CLOCKING_MODE    => "common_clock",
            FIFO_MEMORY_TYPE => "auto",
            CASCADE_HEIGHT   => 0,
            PACKET_FIFO      => "true",
            FIFO_DEPTH       => PACKET_FIFO_DEPTH,
            TDATA_WIDTH      => 64,
            TID_WIDTH        => 1,
            TDEST_WIDTH      => 1,
            TUSER_WIDTH      => 80,
            ECC_MODE         => "no_ecc",
            RELATED_CLOCKS   => 0,
            USE_ADV_FEATURES => "0000",

            WR_DATA_COUNT_WIDTH => 1,
            RD_DATA_COUNT_WIDTH => 1,
            PROG_FULL_THRESH    => 10,
            PROG_EMPTY_THRESH   => 10,
            SIM_ASSERT_CHK      => 0,
            CDC_SYNC_STAGES     => 2
        )
        port map(
            s_aclk => clk,
            m_aclk => clk,
            s_aresetn => rstn,

            s_axis_tdata  => s_axis_tdata,
            s_axis_tkeep  => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            s_axis_tuser  => s_axis_tuser,
            -- not used
            s_axis_tstrb => (others => '1'),
            s_axis_tid   => (others => '0'),
            s_axis_tdest => (others => '0'),

            m_axis_tdata  => m_axis_fifo_tdata,
            m_axis_tvalid => m_axis_fifo_tvalid,
            m_axis_tlast  => m_axis_fifo_tlast,
            m_axis_tready => m_axis_fifo_tready,
            m_axis_tuser  => m_axis_fifo_tuser,
            --not used
            m_axis_tstrb => open,
            m_axis_tkeep => open,
            m_axis_tid   => open,
            m_axis_tdest => open,

            -- flags (disabled)
            prog_full_axis     => open,
            wr_data_count_axis => open,
            almost_full_axis   => open,
            prog_empty_axis    => open,
            rd_data_count_axis => open,
            almost_empty_axis  => open,

            -- ECC (disabled)
            injectsbiterr_axis => '0',
            injectdbiterr_axis => '0',
            sbiterr_axis       => open,
            dbiterr_axis       => open
        );
    m_axis_fifo_tready <= m_axis_tready and packet_fifo_tready;

end architecture;