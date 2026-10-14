-- Written by Yuval Peleg & Aylon Feraru Jul.2026
-- First passes the entire packet through a FIFO to count its length
-- then constructs the UDP header and sends it along with the payload to the next block.
-- ATTENTION: checksum isn't computed (set to all zeros)

-- Timing consideration for entire TX path:
-- manageable speed of jumbo packets:
--       8958 byte payload + 42 byte header = 9000 byte
--       8958 byte payload / 9000 byte total packet size = 99.53% useful packet fraction
--       10Gbps * 99.53% = 9.953Gbps useful data transfer
--
-- manageable speed of smaller packets:
--       18 byte payload + 42 byte header = 60 byte
--       18 byte payload / 60 byte total packet size = 30% useful packet fraction
--       10Gbps * 30% = 3Gbps useful data transfer

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

-- for instantiating Vivado IPs
library xpm;
use xpm.vcomponents.all;


entity tx_udp is
    generic(
        PACKET_FIFO_DEPTH : integer := 2048;
        LENGTH_FIFO_DEPTH : integer := 2048
    );
    port (
        clk, rstn : in std_logic;

        -- Input AXIS
        s_axis_tdata  : in std_logic_vector(63 downto 0);
        s_axis_tkeep  : in std_logic_vector(7 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast  : in std_logic;
        s_axis_tready : out std_logic;

        -- Output AXIS
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tuser  : out std_logic_vector(79 downto 0);
        m_axis_tready : in std_logic;

        conf_port : in std_logic_vector(15 downto 0);

        dst_port  : in std_logic_vector(15 downto 0);
        dst_ip    : in std_logic_vector(31 downto 0);
        dst_mac   : in std_logic_vector(47 downto 0)
    );
end tx_udp;

architecture rtl of tx_udp is

    -----------------------------------------------------------------
    -- constants & declarations
    -----------------------------------------------------------------
    constant MIN_UDP_PAYLOAD_LEN : integer := 18;

    -----------------------------------------------------------------
    -- internal signals
    -----------------------------------------------------------------
    -- length counting
    signal len_counter : unsigned(15 downto 0) := (others => '0');
    
    signal s_axis_len_tdata  : std_logic_vector(15 downto 0) := (others => '0');
    signal s_axis_len_tkeep  : std_logic_vector(1 downto 0)  := (others => '0');
    signal s_axis_len_tvalid : std_logic := '0';
    signal s_axis_len_tuser  : std_logic_vector(95 downto 0) := (others => '0');

    signal m_axis_len_tdata  : std_logic_vector(15 downto 0) := (others => '0');
    signal m_axis_len_tvalid : std_logic := '0';
    signal m_axis_len_tuser  : std_logic_vector(95 downto 0) := (others => '0');
    signal m_axis_len_tready : std_logic := '0';

    -- destination latching
    signal latch_dst_port : std_logic_vector(15 downto 0) := (others => '0');
    signal latch_dst_ip   : std_logic_vector(31 downto 0) := (others => '0');
    signal latch_dst_mac  : std_logic_vector(47 downto 0) := (others => '0');
    signal dst_latched    : std_logic := '0';

    -- sending packets
    signal data_len             : integer range 0 to 65535 := 0;
    signal payload_len          : integer range 0 to 65535 := 0;
    signal padding_counter      : integer range 0 to 17    := 0; -- worst case scenario (payload size is 1 byte) amount of padding needed is 17 bytes
    signal m_axis_tvalid_buffer : std_logic := '0';

    signal s_axis_packet_tready : std_logic := '0';

    signal m_axis_packet_tdata  : std_logic_vector(63 downto 0) := (others => '0');
    signal m_axis_packet_tkeep  : std_logic_vector(7 downto 0)  := (others => '0');
    signal m_axis_packet_tvalid : std_logic := '0';
    signal m_axis_packet_tlast  : std_logic := '0';
    signal m_axis_packet_tready : std_logic := '0';

    signal logic_packet_tready : std_logic := '0';

    -----------------------------------------------------------------
    -- state machine
    -----------------------------------------------------------------
    type state_type is (header, payload, padding);
    signal state : state_type := header;

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
                m_axis_tuser         <= (others => '0');

                logic_packet_tready <= '0';

                padding_counter <= 0;

                state <= header;

            else
                case state is

                    when header =>
                        if(m_axis_tvalid_buffer = '0' or m_axis_tready = '1') then
                            m_axis_tdata         <= (others => '0');
                            m_axis_tkeep         <= (others => '0');
                            m_axis_tvalid_buffer <= '0';
                            m_axis_tlast         <= '0';

                            logic_packet_tready <= '0';

                            data_len    <= 0;
                            payload_len <= 0;

                            if(m_axis_len_tvalid = '1') then
                                m_axis_tdata         <= conf_port & m_axis_len_tuser(15 downto 0) & std_logic_vector(8 + unsigned(m_axis_len_tdata)) & (15 downto 0 => '0');
                                m_axis_tkeep         <= x"FF";
                                m_axis_tvalid_buffer <= '1';
                                m_axis_tlast         <= '0';
                                m_axis_tuser         <= m_axis_len_tuser(95 downto 16);

                                data_len <= to_integer(unsigned(m_axis_len_tdata));

                                logic_packet_tready <= '1';
                                state <= payload;
                            end if;
                        end if;


                    when payload =>
                        if(m_axis_packet_tvalid = '1' and m_axis_tready = '1') then
                            m_axis_tdata         <= m_axis_packet_tdata;
                            m_axis_tkeep         <= m_axis_packet_tkeep;
                            m_axis_tvalid_buffer <= '1';
                            m_axis_tlast         <= '0';

                            payload_len <= payload_len + 8;

                            if(m_axis_packet_tlast = '1') then
                                logic_packet_tready <= '0';

                                -- doesn't need padding
                                if(data_len >= MIN_UDP_PAYLOAD_LEN) then
                                    m_axis_tlast      <= '1';
                                    state <= header;

                                -- needs padding, starts this word
                                elsif(m_axis_packet_tkeep /= x"FF") then -- (tkeep cannot be x"00" as well)
                                    -- zeroing rest
                                    m_axis_tdata <= (others => '0');
                                    -- outputting rest of data bytes
                                    m_axis_tdata(63 downto 64 - (8 * (data_len - payload_len))) <= m_axis_packet_tdata(63 downto 64 - (8 * (data_len - payload_len)));
                                
                                    -- only case where padding is needed and can be completed in same word (1 byte of padding)
                                    if(data_len = 17) then
                                        -- keeping 2 bytes
                                        m_axis_tkeep <= x"C0";

                                        m_axis_tlast      <= '1';
                                        state <= header;

                                    -- still needs more padding
                                    else
                                        m_axis_tkeep <= x"FF";

                                        padding_counter <= MIN_UDP_PAYLOAD_LEN - payload_len - 8;
                                        state <= padding;
                                    end if;

                                -- current word full of data, padding starts next word
                                else
                                    padding_counter <= MIN_UDP_PAYLOAD_LEN - data_len;
                                    state <= padding;

                                end if;
                            end if;
                        elsif(m_axis_tready = '1') then
                            m_axis_tdata         <= (others => '0');
                            m_axis_tkeep         <= (others => '0');
                            m_axis_tvalid_buffer <= '0';
                            m_axis_tlast         <= '0';
                        end if;


                    when padding =>
                        if(m_axis_tready = '1') then
                            m_axis_tdata         <= (others => '0');
                            m_axis_tvalid_buffer <= '1';

                            if(padding_counter <= 8) then
                                m_axis_tkeep(7 downto 8-padding_counter) <= (others => '1');
                                m_axis_tkeep(7-padding_counter downto 0) <= (others => '0');
                                m_axis_tlast <= '1';

                                state <= header;
                            else
                                m_axis_tkeep <= x"FF";
                                m_axis_tlast <= '0';

                                padding_counter <= padding_counter - 8;
                            end if;
                        end if;

                end case;

            end if;
        end if;
    end process;
    m_axis_tvalid <= m_axis_tvalid_buffer;
    -- popping stale length each time it's read by header state
    m_axis_len_tready <= '1' when state = header                                      and
                                  (m_axis_tvalid_buffer = '0' or m_axis_tready = '1') and
                                  m_axis_len_tvalid = '1'
                             else '0';


    ----------------------------------------------------------------------------
    -- Length Counting
    ----------------------------------------------------------------------------
    process(clk, rstn) is
        variable tkeep_counter : unsigned(3 downto 0);
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                s_axis_len_tdata  <= (others => '0');
                s_axis_len_tkeep  <= (others => '0');
                s_axis_len_tvalid <= '0';
                s_axis_len_tuser  <= (others => '0');

                len_counter <= (others => '0');

                latch_dst_port <= (others => '0');
                latch_dst_ip   <= (others => '0');
                latch_dst_mac  <= (others => '0');
                dst_latched    <= '0';

            else
                s_axis_len_tdata  <= (others => '0');
                s_axis_len_tkeep  <= (others => '0');
                s_axis_len_tvalid <= '0';

                if(s_axis_tvalid = '1' and s_axis_packet_tready = '1') then
                    if(dst_latched = '0') then
                        latch_dst_port <= dst_port;
                        latch_dst_ip   <= dst_ip;
                        latch_dst_mac  <= dst_mac;
                        dst_latched    <= '1';
                    end if;

                    len_counter <= len_counter + 8;

                    if(s_axis_tlast = '1') then
                        tkeep_counter := (others => '0');
                        for i in 0 to 7 loop
                            tkeep_counter := tkeep_counter + unsigned'("" & s_axis_tkeep(i));
                        end loop;

                        s_axis_len_tdata  <= std_logic_vector(len_counter + tkeep_counter);
                        s_axis_len_tkeep  <= "11";
                        s_axis_len_tvalid <= '1';

                        -- single beat packet
                        if(dst_latched = '0') then
                            s_axis_len_tuser <= dst_mac & dst_ip & dst_port;
                        else
                            s_axis_len_tuser <= latch_dst_mac & latch_dst_ip & latch_dst_port;
                        end if;

                        len_counter <= (others => '0');

                        dst_latched <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;                


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
            TUSER_WIDTH      => 1,
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
            s_axis_tready => s_axis_packet_tready,
            -- not used
            s_axis_tstrb => (others => '1'),
            s_axis_tid   => (others => '0'),
            s_axis_tdest => (others => '0'),
            s_axis_tuser => (others => '0'),

            m_axis_tdata  => m_axis_packet_tdata,
            m_axis_tkeep  => m_axis_packet_tkeep,
            m_axis_tvalid => m_axis_packet_tvalid,
            m_axis_tlast  => m_axis_packet_tlast,
            m_axis_tready => m_axis_packet_tready,
            --not used
            m_axis_tuser => open,
            m_axis_tstrb => open,
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
    s_axis_tready        <= s_axis_packet_tready;
    m_axis_packet_tready <= m_axis_tready and logic_packet_tready;


    length_fifo_inst : xpm_fifo_axis
        generic map(
            CLOCKING_MODE    => "common_clock",
            FIFO_MEMORY_TYPE => "auto",
            CASCADE_HEIGHT   => 0,
            PACKET_FIFO      => "false",
            FIFO_DEPTH       => LENGTH_FIFO_DEPTH,
            TDATA_WIDTH      => 16,
            TID_WIDTH        => 1,
            TDEST_WIDTH      => 1,
            TUSER_WIDTH      => 96,
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

            s_axis_tdata  => s_axis_len_tdata,
            s_axis_tkeep  => s_axis_len_tkeep,
            s_axis_tvalid => s_axis_len_tvalid,
            s_axis_tuser  => s_axis_len_tuser,
            -- not used
            s_axis_tstrb => (others => '1'),
            s_axis_tid   => (others => '0'),
            s_axis_tdest => (others => '0'),
            s_axis_tlast => '0',
            s_axis_tready => open,

            m_axis_tdata  => m_axis_len_tdata,
            m_axis_tvalid => m_axis_len_tvalid,
            m_axis_tready => m_axis_len_tready,
            m_axis_tuser  => m_axis_len_tuser,
            --not used
            m_axis_tstrb => open,
            m_axis_tkeep => open,
            m_axis_tid   => open,
            m_axis_tdest => open,
            m_axis_tlast => open,

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

end architecture;