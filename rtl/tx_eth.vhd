-- Written by Yuval Peleg & Aylon Feraru  Jul.2026
-- Constructs and sends Ethernet header and sends payload afterwards

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
-- +-----------------+-----------+--------------------------------+

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- for instantiating Vivado IPs
library xpm;
use xpm.vcomponents.all;

entity tx_eth is
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
        s_axis_tuser  : in std_logic_vector(47 downto 0);
        s_axis_tready : out std_logic;

        -- Output AXIS
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in std_logic;

        conf_mac : in std_logic_vector (47 downto 0)
    );
end tx_eth;

architecture rtl of tx_eth is

    -----------------------------------------------------------------
    -- constants & declarations
    -----------------------------------------------------------------
    constant ETHERTYPE_IPV4 : std_logic_vector(15 downto 0) := x"0800";

    -----------------------------------------------------------------
    -- internal signals
    -----------------------------------------------------------------
    signal m_axis_tvalid_buffer : std_logic := '0';

    signal m_axis_fifo_tdata  : std_logic_vector(63 downto 0) := (others => '0');
    signal m_axis_fifo_tkeep  : std_logic_vector(7 downto 0)  := (others => '0');
    signal m_axis_fifo_tvalid : std_logic := '0';
    signal m_axis_fifo_tlast  : std_logic := '0';
    signal m_axis_fifo_tuser  : std_logic_vector(47 downto 0) := (others => '0');
    signal m_axis_fifo_tready : std_logic := '0';

    signal packet_fifo_tready : std_logic := '0';

    -- buffers for carrying data to the next word
    signal tdata_buffer : std_logic_vector(47 downto 0) := (others => '0');
    signal tkeep_buffer : std_logic_vector(5 downto 0)  := (others => '0');

    -----------------------------------------------------------------
    -- state machine
    -----------------------------------------------------------------
    type state_type is (header, payload, extra_word);
    signal state : state_type := header;
    signal header_word_count : integer range 0 to 1 := 0;

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

                packet_fifo_tready <= '0';
                header_word_count  <= 0;

                state <= header;

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
                                        m_axis_tdata <= m_axis_fifo_tuser & conf_mac(47 downto 32);

                                        -- takes two clocks to get the next word of data
                                        -- one raises tready to '1', the other for the FIFO to receive
                                        --  and output the next word.
                                        packet_fifo_tready <= '1';

                                    when 1 =>
                                        m_axis_tdata   <= conf_mac(31 downto 0) & ETHERTYPE_IPV4 & m_axis_fifo_tdata(63 downto 48);
                                        tdata_buffer <= m_axis_fifo_tdata(47 downto 0);

                                        header_word_count <= 0;
                                        state             <= payload;

                                end case;
                            end if;
                        end if;


                    when payload =>
                        if(m_axis_fifo_tvalid = '1' and m_axis_tready = '1') then
                            m_axis_tdata         <= tdata_buffer & m_axis_fifo_tdata(63 downto 48);
                            m_axis_tkeep         <= x"FF";
                            m_axis_tvalid_buffer <= '1';
                            m_axis_tlast         <= '0';

                            tdata_buffer <= m_axis_fifo_tdata(47 downto 0);
                            if(m_axis_fifo_tlast = '1') then
                                packet_fifo_tready <= '0';

                                -- completely fits in current word
                                if(m_axis_fifo_tkeep = "11000000") then
                                    m_axis_tlast <= '1';
                                    state        <= header;
                                -- fits in current with leftover space
                                elsif(m_axis_fifo_tkeep = "10000000") then
                                    m_axis_tdata <= tdata_buffer & m_axis_fifo_tdata(63 downto 56) & (7 downto 0 => '0');
                                    m_axis_tkeep <= x"FE";
                                    m_axis_tlast <= '1';
                                    state        <= header;
                                -- doesn't fit in current word
                                else
                                    tkeep_buffer <= m_axis_fifo_tkeep(5 downto 0);
                                    state <= extra_word;
                                end if;
                            end if;
                        end if;


                    when extra_word =>
                        if(m_axis_tready = '1') then
                            m_axis_tdata         <= tdata_buffer & (15 downto 0 => '0');
                            m_axis_tkeep         <= tkeep_buffer & "00";
                            m_axis_tvalid_buffer <= '1';
                            m_axis_tlast         <= '1';

                            state <= header;
                        end if;

                end case;

            end if;
        end if;
    end process;
    m_axis_tvalid <= m_axis_tvalid_buffer;            

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
            TUSER_WIDTH      => 48,
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
            s_axis_tuser  => s_axis_tuser,
            s_axis_tready => s_axis_tready,
            -- not used
            s_axis_tstrb => (others => '1'),
            s_axis_tid   => (others => '0'),
            s_axis_tdest => (others => '0'),

            m_axis_tdata  => m_axis_fifo_tdata,
            m_axis_tkeep  => m_axis_fifo_tkeep,
            m_axis_tvalid => m_axis_fifo_tvalid,
            m_axis_tlast  => m_axis_fifo_tlast,
            m_axis_tuser  => m_axis_fifo_tuser,
            m_axis_tready => m_axis_fifo_tready,
            --not used
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
    m_axis_fifo_tready <= m_axis_tready and packet_fifo_tready;

end architecture;