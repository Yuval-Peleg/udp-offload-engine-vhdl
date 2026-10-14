-- Written by Yuval Peleg & Aylon Feraru Jun.2026
-- Receives each packet from the XXV ip and passes it along only if it's valid
-- based on tuser coming from the XXV ip

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- for instantiating Vivado IPs
library xpm;
use xpm.vcomponents.all;

entity circular_buffer_filter is
    port (
        clk, rstn : in std_logic;
        
        -- Ethernet block inputs
        s_axis_tdata  : in std_logic_vector(63 downto 0);
        s_axis_tkeep  : in std_logic_vector(7 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast  : in std_logic;
        s_axis_tuser  : in std_logic;
        s_axis_tready : out std_logic;
        
        -- Filtered packet output
        m_axis_tdata  : out  std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in std_logic
    );
end circular_buffer_filter;

architecture rtl of circular_buffer_filter is
    -- AXI-Stream constants
    constant TDATA_WIDTH           : integer := 64;
    constant COMPACTED_TKEEP_WIDTH : integer := 3;
    constant TLAST_WIDTH           : integer := 1;

    -- BRAM constants
    constant BRAM_DEPTH      : integer := 2048;
    constant BRAM_WORD_WIDTH : integer := TDATA_WIDTH + COMPACTED_TKEEP_WIDTH + TLAST_WIDTH;
    constant BRAM_ADDR_WIDTH : integer := 11;

    -- tkeep compacting signals
    signal tkeep_compacted_in  : std_logic_vector(2 downto 0);
    signal tkeep_compacted_out : std_logic_vector(2 downto 0);

    -- Write & Read pointers
    -- addresses are [BRAM_ADDR_WIDTH] bits, the last bit of each pointer is to get rid of ambiguity
    -- in the case where the foremost pointer [wr_ptr] and the most trailing pointer [rd_ptr]
    -- are equal (which could either mean fully empty or completely full BRAM)
    signal wr_ptr     : unsigned(BRAM_ADDR_WIDTH downto 0) := (others => '0');
    signal rd_ptr     : unsigned(BRAM_ADDR_WIDTH downto 0) := (others => '0');
    signal commit_ptr : unsigned(BRAM_ADDR_WIDTH downto 0) := (others => '0');

    signal wr_data : std_logic_vector(BRAM_WORD_WIDTH-1 downto 0) := (others => '0');
    signal wr_en   : std_logic := '0';
    signal wr_full : std_logic := '0';
    signal dumping : std_logic := '0';

    signal rd_empty   : std_logic := '0';
    signal rd_advance : std_logic := '0';
    signal rd_valid   : std_logic := '0';

    signal valid_stage1 : std_logic := '0';
    signal valid_stage2 : std_logic := '0';

    signal bram_dout : std_logic_vector(BRAM_WORD_WIDTH-1 downto 0) := (others => '0');
    signal bram_rst  : std_logic := '0';

begin

    ----------------------------------------------------------------------------
    -- Write side
    ----------------------------------------------------------------------------

    -- compacting tkeep into a 3 bit count because tkeep must be contiguous and never x"00" in this design
    -- compacting tkeep reduces BRAM usage
    tkeep_compacted_in <= "000" when(s_axis_tkeep = x"80") else
                      "001" when(s_axis_tkeep = x"C0") else
                      "010" when(s_axis_tkeep = x"E0") else
                      "011" when(s_axis_tkeep = x"F0") else
                      "100" when(s_axis_tkeep = x"F8") else
                      "101" when(s_axis_tkeep = x"FC") else
                      "110" when(s_axis_tkeep = x"FE") else
                      "111";
    -- packing S_AXIS bus into a BRAM word
    wr_data <= s_axis_tlast & tkeep_compacted_in & s_axis_tdata;

    -- BRAM is full when [wr_ptr] is a whole rotation ahead of [rd_ptr]
    -- the MSB in each pointer alternates each loop
    wr_full <= '1' when (wr_ptr(BRAM_ADDR_WIDTH) /= rd_ptr(BRAM_ADDR_WIDTH)) and
                        (wr_ptr(BRAM_ADDR_WIDTH-1 downto 0) = rd_ptr(BRAM_ADDR_WIDTH-1 downto 0))
                else '0';
    s_axis_tready <= (not wr_full) or dumping;
    wr_en         <= s_axis_tvalid and (not wr_full) and (not dumping);


    write_proc : process(clk)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                wr_ptr     <= (others => '0');
                commit_ptr <= (others => '0');
                dumping    <= '0';
            elsif(dumping = '1') then
                -- waiting until the packet ends
                if(s_axis_tvalid = '1' and s_axis_tlast = '1') then
                    dumping <= '0';
                end if;
            -- bram is full of uncommitted data but data still coming
            elsif(s_axis_tvalid = '1' and wr_full = '1' and rd_empty = '1') then
                -- setting write pointer back to last commit
                wr_ptr <= commit_ptr;
                if(s_axis_tlast /= '1') then
                    dumping <= '1';
                end if;
            elsif(wr_en = '1') then
                -- last beat of packet
                if(s_axis_tlast = '1') then
                    if(s_axis_tuser = '1') then
                        -- packet is invalid, roll back to last commit
                        wr_ptr <= commit_ptr;
                    else
                        -- packet is valid, commit everything up-to and including current beat
                        wr_ptr     <= wr_ptr + 1;
                        commit_ptr <= wr_ptr + 1;
                    end if;

                -- not last beat of packet
                else
                    wr_ptr <= wr_ptr + 1;
                end if;
            end if;
        end if;
    end process;



    ----------------------------------------------------------------------------
    -- Read side
    ----------------------------------------------------------------------------

    -- if [rd_ptr] reaches [commit_ptr] there is no new data to read
    rd_empty <= '1' when rd_ptr = commit_ptr else '0';

    -- can continue reading if output stage currently empty
    -- or current output is being consumed by the downstream block
    rd_advance <= (not valid_stage2) or m_axis_tready;

    rd_valid <= rd_advance and (not rd_empty);

    read_proc : process(clk)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                rd_ptr       <= (others => '0');
                valid_stage1 <= '0';
                valid_stage2 <= '0';
            else
                if(rd_advance = '1') then
                    valid_stage1 <= rd_valid;
                    valid_stage2 <= valid_stage1;
                end if;

                if(rd_valid = '1') then
                    rd_ptr <= rd_ptr + 1;
                end if;
            end if;
        end if;
    end process;

    -- M_AXIS output
    m_axis_tdata        <= bram_dout(TDATA_WIDTH-1 downto 0);
    tkeep_compacted_out <= bram_dout(TDATA_WIDTH + COMPACTED_TKEEP_WIDTH-1 downto TDATA_WIDTH);
    m_axis_tkeep        <= x"80" when(tkeep_compacted_out = "000") else
                           x"C0" when(tkeep_compacted_out = "001") else
                           x"E0" when(tkeep_compacted_out = "010") else
                           x"F0" when(tkeep_compacted_out = "011") else
                           x"F8" when(tkeep_compacted_out = "100") else
                           x"FC" when(tkeep_compacted_out = "101") else
                           x"FE" when(tkeep_compacted_out = "110") else
                           x"FF";
    m_axis_tlast        <= bram_dout(TDATA_WIDTH + COMPACTED_TKEEP_WIDTH);
    m_axis_tvalid       <= valid_stage2;



    ----------------------------------------------------------------------------
    -- Storage: BRAM , stand-alone , simple dual port
    ----------------------------------------------------------------------------

    bram_rst <= not rstn;

    bram_inst : xpm_memory_sdpram
        generic map(
            MEMORY_SIZE             => BRAM_DEPTH * BRAM_WORD_WIDTH,
            MEMORY_PRIMITIVE        => "block",
            CLOCKING_MODE           => "common_clock",
            ECC_MODE                => "no_ecc",
            MEMORY_INIT_FILE        => "none",
            MEMORY_INIT_PARAM       => "",
            USE_MEM_INIT            => 1,
            USE_MEM_INIT_MMI        => 0,
            WAKEUP_TIME             => "disable_sleep",
            AUTO_SLEEP_TIME         => 0,
            MESSAGE_CONTROL         => 0,
            USE_EMBEDDED_CONSTRAINT => 0,
            MEMORY_OPTIMIZATION     => "true",
            CASCADE_HEIGHT          => 0,
            SIM_ASSERT_CHK          => 0,
            WRITE_PROTECT           => 1,

            -- PORT A (Write)
            WRITE_DATA_WIDTH_A => BRAM_WORD_WIDTH,
            BYTE_WRITE_WIDTH_A => BRAM_WORD_WIDTH,
            ADDR_WIDTH_A       => BRAM_ADDR_WIDTH,

            -- PORT B (Read)
            READ_DATA_WIDTH_B  => BRAM_WORD_WIDTH,
            ADDR_WIDTH_B       => BRAM_ADDR_WIDTH,
            READ_RESET_VALUE_B => "0",
            RST_MODE_B         => "SYNC",
            READ_LATENCY_B     => 2,
            WRITE_MODE_B       => "no_change"
        )
        port map(
            sleep => '0',

            -- Write side
            clka            => clk,
            ena             => wr_en,
            addra           => std_logic_vector(wr_ptr(BRAM_ADDR_WIDTH-1 downto 0)),
            dina            => wr_data,
            wea             => "1",
            injectsbiterra => '0',
            injectdbiterra => '0',

            -- Read side
            clkb     => clk,
            rstb     => bram_rst,
            addrb    => std_logic_vector(rd_ptr(BRAM_ADDR_WIDTH-1 downto 0)),
            doutb    => bram_dout,
            enb      => rd_valid,
            regceb   => rd_advance,
            sbiterrb => open,
            dbiterrb => open
        );


end architecture;


