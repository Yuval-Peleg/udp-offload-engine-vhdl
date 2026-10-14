-- Written by Yuval Peleg & Aylon Feraru  Jul.2026
-- Top level of the UDP Offload Engine, connects all internal components

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- for instantiating Vivado IPs
library xpm;
use xpm.vcomponents.all;

entity uoe is
    port (
        clk, rstn : in std_logic;
        
        --------------------- RX --------------------------
        -- MAC RX AXIS
        mac_rx_tdata  : in std_logic_vector(63 downto 0);
        mac_rx_tkeep  : in std_logic_vector(7 downto 0);
        mac_rx_tuser  : in std_logic_vector(0 downto 0);
        mac_rx_tvalid : in std_logic;
        mac_rx_tlast  : in std_logic;
        mac_rx_tready : out std_logic;

        -- UDP RX AXIS
        udp_rx_tdata  : out std_logic_vector(63 downto 0);
        udp_rx_tkeep  : out std_logic_vector(7 downto 0);
        udp_rx_tvalid : out std_logic;
        udp_rx_tlast  : out std_logic;
        udp_rx_tuser  : out std_logic;

        -- rx data
        udp_rx_src_mac  : out std_logic_vector(47 downto 0);
        udp_rx_src_ip   : out std_logic_vector(31 downto 0);
        udp_rx_src_port : out std_logic_vector(15 downto 0);
        udp_rx_dst_port : out std_logic_vector(15 downto 0);


        --------------------- TX --------------------------
        -- MAC TX AXIS
        mac_tx_tdata  : out std_logic_vector(63 downto 0);
        mac_tx_tkeep  : out std_logic_vector(7 downto 0);
        mac_tx_tvalid : out std_logic;
        mac_tx_tlast  : out std_logic;
        mac_tx_tready : in std_logic;

        -- UDP TX AXIS
        udp_tx_tdata  : in std_logic_vector(63 downto 0);
        udp_tx_tkeep  : in std_logic_vector(7 downto 0);
        udp_tx_tvalid : in std_logic;
        udp_tx_tlast  : in std_logic;
        udp_tx_tready : out std_logic;

        -- tx config
        conf_tx_dst_mac  : in std_logic_vector(47 downto 0);
        conf_tx_dst_ip   : in std_logic_vector(31 downto 0);
        conf_tx_dst_port : in std_logic_vector(15 downto 0);


        ------------------- CONFIGS ------------------------
        -- block configs
        conf_mac  : in std_logic_vector(47 downto 0);
        conf_ip   : in std_logic_vector(31 downto 0);
        conf_port : in std_logic_vector(15 downto 0)
    );
end uoe;

architecture rtl of uoe is

    -----------------------------------------------------------------------------------------
    --                                 internal signals
    -----------------------------------------------------------------------------------------
    constant MIN_RST_CLK : integer := 64;
    signal rst_clk_count : integer range 0 to MIN_RST_CLK-1 := 0;
    signal rstn_meta, rstn_ff, rstn_sync : std_logic := '0';
    -- attribute that makes sure the sync logic is all in the same physical location on the die itself
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of rstn_meta : signal is "TRUE";
    attribute ASYNC_REG of rstn_ff   : signal is "TRUE";
    attribute ASYNC_REG of rstn_sync : signal is "TRUE";


    
    --------------------- RX --------------------------
    -- rx_endi
    signal out_rx_endi_tdata : std_logic_vector(63 downto 0);
    signal out_rx_endi_tkeep : std_logic_vector(7 downto 0);

    -- rx_fifo
    signal out_rx_fifo_tdata  : std_logic_vector(63 downto 0);
    signal out_rx_fifo_tkeep  : std_logic_vector(7 downto 0);
    signal out_rx_fifo_tuser  : std_logic_vector(0 downto 0);
    signal out_rx_fifo_tvalid : std_logic;
    signal out_rx_fifo_tlast  : std_logic;
    signal out_rx_fifo_tready : std_logic;

    -- circ_fifo
    signal out_circ_fifo_tdata  : std_logic_vector(63 downto 0);
    signal out_circ_fifo_tkeep  : std_logic_vector(7 downto 0);
    signal out_circ_fifo_tvalid : std_logic;
    signal out_circ_fifo_tlast  : std_logic;

    -- rx_eth
    signal out_rx_eth_tdata  : std_logic_vector(63 downto 0);
    signal out_rx_eth_tkeep  : std_logic_vector(7 downto 0);
    signal out_rx_eth_tvalid : std_logic;
    signal out_rx_eth_tlast  : std_logic;

    -- rx_ipv4
    signal out_rx_ipv4_tdata  : std_logic_vector(63 downto 0);
    signal out_rx_ipv4_tkeep  : std_logic_vector(7 downto 0);
    signal out_rx_ipv4_tvalid : std_logic;
    signal out_rx_ipv4_tlast  : std_logic;
    signal out_rx_ipv4_tuser  : std_logic;



    --------------------- TX --------------------------
    -- tx_udp
    signal out_tx_udp_tdata  : std_logic_vector(63 downto 0);
    signal out_tx_udp_tkeep  : std_logic_vector(7 downto 0);
    signal out_tx_udp_tvalid : std_logic;
    signal out_tx_udp_tlast  : std_logic;
    signal out_tx_udp_tuser  : std_logic_vector(79 downto 0);
    signal out_tx_udp_tready : std_logic;

    -- tx_ipv4
    signal out_tx_ipv4_tdata  : std_logic_vector(63 downto 0);
    signal out_tx_ipv4_tkeep  : std_logic_vector(7 downto 0);
    signal out_tx_ipv4_tvalid : std_logic;
    signal out_tx_ipv4_tlast  : std_logic;
    signal out_tx_ipv4_tuser  : std_logic_vector(47 downto 0);
    signal out_tx_ipv4_tready : std_logic;

    -- tx_eth
    signal out_tx_eth_tdata  : std_logic_vector(63 downto 0);
    signal out_tx_eth_tkeep  : std_logic_vector(7 downto 0);
    signal out_tx_eth_tvalid : std_logic;
    signal out_tx_eth_tlast  : std_logic;
    signal out_tx_eth_tready : std_logic;
    
    -- tx_fifo
    signal out_tx_fifo_tdata  : std_logic_vector(63 downto 0);
    signal out_tx_fifo_tkeep  : std_logic_vector(7 downto 0);
    signal out_tx_fifo_tvalid : std_logic;
    signal out_tx_fifo_tlast  : std_logic;
    signal out_tx_fifo_tready : std_logic;



    -------------------- ARP --------------------------
    -- arp_handler
    signal out_arp_handler_tdata  : std_logic_vector(63 downto 0);
    signal out_arp_handler_tkeep  : std_logic_vector(7 downto 0);
    signal out_arp_handler_tvalid : std_logic;
    signal out_arp_handler_tlast  : std_logic;
 
    -- arp_fifo
    signal out_arp_fifo_tdata  : std_logic_vector(63 downto 0);
    signal out_arp_fifo_tkeep  : std_logic_vector(7 downto 0);
    signal out_arp_fifo_tvalid : std_logic;
    signal out_arp_fifo_tlast  : std_logic;
    signal out_arp_fifo_tready : std_logic;
    signal out_arp_fifo_full   : std_logic;
    signal out_arp_fifo_wready : std_logic;

    -- priority_handler
    signal out_priority_tdata  : std_logic_vector(63 downto 0);
    signal out_priority_tkeep  : std_logic_vector(7 downto 0);

begin
    -----------------------------------------------------------------------------------------
    --                             Reset Stability Process
    -----------------------------------------------------------------------------------------
    process(clk) is
    begin
        if(rising_edge(clk)) then
            rstn_meta <= rstn;
            rstn_ff <= rstn_meta;

            if(rstn_ff = '0') then
                rstn_sync     <= '0';
                rst_clk_count <= MIN_RST_CLK - 1;
            elsif(rst_clk_count /= 0) then
                rstn_sync     <= '0';
                rst_clk_count <= rst_clk_count - 1;
            else
                rstn_sync <= '1';
            end if;
        end if;
    end process;


    -----------------------------------------------------------------------------------------
    --                                      RX
    -----------------------------------------------------------------------------------------
    rx_endi : entity work.endianness_converter
        port map(
            tdata_in => mac_rx_tdata,
            tkeep_in => mac_rx_tkeep,

            tdata_out => out_rx_endi_tdata,
            tkeep_out => out_rx_endi_tkeep
        );

    rx_fifo : xpm_fifo_axis
        generic map(
            CLOCKING_MODE    => "common_clock",
            FIFO_MEMORY_TYPE => "auto",
            CASCADE_HEIGHT   => 0,
            PACKET_FIFO      => "false",
            FIFO_DEPTH       => 512,
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
            s_aresetn => rstn_sync,

            -- input
            s_axis_tdata  => out_rx_endi_tdata,
            s_axis_tkeep  => out_rx_endi_tkeep,
            s_axis_tvalid => mac_rx_tvalid,
            s_axis_tlast  => mac_rx_tlast,
            s_axis_tuser  => mac_rx_tuser,
            s_axis_tready => mac_rx_tready,
            -- not used
            s_axis_tstrb => (others => '1'),
            s_axis_tid   => (others => '0'),
            s_axis_tdest => (others => '0'),
            
            -- output
            m_axis_tdata  => out_rx_fifo_tdata,
            m_axis_tkeep  => out_rx_fifo_tkeep,
            m_axis_tvalid => out_rx_fifo_tvalid,
            m_axis_tlast  => out_rx_fifo_tlast,
            m_axis_tuser  => out_rx_fifo_tuser,
            m_axis_tready => out_rx_fifo_tready,
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

    circ_fifo : entity work.circular_buffer_filter
        port map (
            clk  => clk,
            rstn => rstn_sync,

            s_axis_tdata  => out_rx_fifo_tdata,
            s_axis_tkeep  => out_rx_fifo_tkeep,
            s_axis_tvalid => out_rx_fifo_tvalid,
            s_axis_tlast  => out_rx_fifo_tlast,
            s_axis_tuser  => out_rx_fifo_tuser(0),
            s_axis_tready => out_rx_fifo_tready,

            m_axis_tdata  => out_circ_fifo_tdata,
            m_axis_tkeep  => out_circ_fifo_tkeep,
            m_axis_tvalid => out_circ_fifo_tvalid,
            m_axis_tlast  => out_circ_fifo_tlast,
            m_axis_tready => '1'
        );

    rx_eth : entity work.rx_eth
        port map (
            clk  => clk, 
            rstn => rstn_sync, 
            
            s_axis_tdata  => out_circ_fifo_tdata, 
            s_axis_tkeep  => out_circ_fifo_tkeep, 
            s_axis_tvalid => out_circ_fifo_tvalid, 
            s_axis_tlast  => out_circ_fifo_tlast, 

            m_axis_tdata  => out_rx_eth_tdata,
            m_axis_tkeep  => out_rx_eth_tkeep,
            m_axis_tvalid => out_rx_eth_tvalid,
            m_axis_tlast  => out_rx_eth_tlast,
            
            conf_mac => conf_mac,
            src_mac => udp_rx_src_mac
        );

    rx_ipv4 : entity work.rx_ipv4
        port map (
            clk  => clk, 
            rstn => rstn_sync, 
            
            s_axis_tdata  => out_rx_eth_tdata, 
            s_axis_tkeep  => out_rx_eth_tkeep, 
            s_axis_tvalid => out_rx_eth_tvalid, 
            s_axis_tlast  => out_rx_eth_tlast, 

            m_axis_tdata  => out_rx_ipv4_tdata,
            m_axis_tkeep  => out_rx_ipv4_tkeep,
            m_axis_tvalid => out_rx_ipv4_tvalid,
            m_axis_tlast  => out_rx_ipv4_tlast,
            m_axis_tuser  => out_rx_ipv4_tuser,
            
            conf_ip => conf_ip,
            src_ip => udp_rx_src_ip
        );

    rx_udp : entity work.rx_udp
        port map (
            clk  => clk, 
            rstn => rstn_sync, 
            
            s_axis_tdata  => out_rx_ipv4_tdata, 
            s_axis_tkeep  => out_rx_ipv4_tkeep, 
            s_axis_tvalid => out_rx_ipv4_tvalid, 
            s_axis_tlast  => out_rx_ipv4_tlast,
            s_axis_tuser  => out_rx_ipv4_tuser,

            m_axis_tdata  => udp_rx_tdata,
            m_axis_tkeep  => udp_rx_tkeep,
            m_axis_tvalid => udp_rx_tvalid,
            m_axis_tlast  => udp_rx_tlast,
            m_axis_tuser  => udp_rx_tuser,
            
            src_port => udp_rx_src_port,
            dst_port => udp_rx_dst_port
        );


    -----------------------------------------------------------------------------------------
    --                                      TX
    -----------------------------------------------------------------------------------------
    tx_udp : entity work.tx_udp
        generic map(
            PACKET_FIFO_DEPTH => 2048,
            LENGTH_FIFO_DEPTH => 2048
        )
        port map(
            clk  => clk, 
            rstn => rstn_sync,

            s_axis_tdata  => udp_tx_tdata,
            s_axis_tkeep  => udp_tx_tkeep,
            s_axis_tvalid => udp_tx_tvalid,
            s_axis_tlast  => udp_tx_tlast,
            s_axis_tready => udp_tx_tready,

            m_axis_tdata  => out_tx_udp_tdata,
            m_axis_tkeep  => out_tx_udp_tkeep,
            m_axis_tvalid => out_tx_udp_tvalid,
            m_axis_tlast  => out_tx_udp_tlast,
            m_axis_tuser  => out_tx_udp_tuser,
            m_axis_tready => out_tx_udp_tready,

            conf_port => conf_port,

            dst_port => conf_tx_dst_port,
            dst_ip   => conf_tx_dst_ip,
            dst_mac  => conf_tx_dst_mac
        );

    tx_ipv4 : entity work.tx_ipv4
        generic map(
            PACKET_FIFO_DEPTH => 16
        )
        port map(
            clk  => clk, 
            rstn => rstn_sync,

            s_axis_tdata  => out_tx_udp_tdata,
            s_axis_tkeep  => out_tx_udp_tkeep,
            s_axis_tvalid => out_tx_udp_tvalid,
            s_axis_tlast  => out_tx_udp_tlast,
            s_axis_tuser  => out_tx_udp_tuser,
            s_axis_tready => out_tx_udp_tready,

            m_axis_tdata  => out_tx_ipv4_tdata,
            m_axis_tkeep  => out_tx_ipv4_tkeep,
            m_axis_tvalid => out_tx_ipv4_tvalid,
            m_axis_tlast  => out_tx_ipv4_tlast,
            m_axis_tuser  => out_tx_ipv4_tuser,
            m_axis_tready => out_tx_ipv4_tready,

            conf_ip => conf_ip
        );

    tx_eth : entity work.tx_eth
        generic map(
            PACKET_FIFO_DEPTH => 16
        )
        port map(
            clk  => clk, 
            rstn => rstn_sync,

            s_axis_tdata  => out_tx_ipv4_tdata,
            s_axis_tkeep  => out_tx_ipv4_tkeep,
            s_axis_tvalid => out_tx_ipv4_tvalid,
            s_axis_tlast  => out_tx_ipv4_tlast,
            s_axis_tuser  => out_tx_ipv4_tuser,
            s_axis_tready => out_tx_ipv4_tready,

            m_axis_tdata  => out_tx_eth_tdata,
            m_axis_tkeep  => out_tx_eth_tkeep,
            m_axis_tvalid => out_tx_eth_tvalid,
            m_axis_tlast  => out_tx_eth_tlast,
            m_axis_tready => out_tx_eth_tready,

            conf_mac => conf_mac
        );

    tx_fifo : xpm_fifo_axis
        generic map(
            CLOCKING_MODE    => "common_clock",
            FIFO_MEMORY_TYPE => "auto",
            CASCADE_HEIGHT   => 0,
            PACKET_FIFO      => "true",
            FIFO_DEPTH       => 512,
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
            s_aresetn => rstn_sync,
            
            -- input
            s_axis_tdata  => out_tx_eth_tdata,
            s_axis_tkeep  => out_tx_eth_tkeep,
            s_axis_tvalid => out_tx_eth_tvalid,
            s_axis_tlast  => out_tx_eth_tlast,
            s_axis_tready => out_tx_eth_tready,
            -- not used
            s_axis_tstrb => (others => '1'),
            s_axis_tid   => (others => '0'),
            s_axis_tdest => (others => '0'),
            s_axis_tuser => (others => '0'),

            -- output
            m_axis_tdata  => out_tx_fifo_tdata,
            m_axis_tkeep  => out_tx_fifo_tkeep,
            m_axis_tvalid => out_tx_fifo_tvalid,
            m_axis_tlast  => out_tx_fifo_tlast,
            m_axis_tready => out_tx_fifo_tready,
            --not used
            m_axis_tuser => open ,
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


    -----------------------------------------------------------------------------------------
    --                                     ARP
    -----------------------------------------------------------------------------------------
    arp_handler : entity work.arp_handler
        port map (
            clk  => clk, 
            rstn => rstn_sync, 
            
            s_axis_tdata  => out_circ_fifo_tdata, 
            s_axis_tkeep  => out_circ_fifo_tkeep, 
            s_axis_tvalid => out_circ_fifo_tvalid, 
            s_axis_tlast  => out_circ_fifo_tlast, 

            m_axis_tdata   => out_arp_handler_tdata,
            m_axis_tkeep   => out_arp_handler_tkeep,
            m_axis_tvalid  => out_arp_handler_tvalid,
            m_axis_tlast   => out_arp_handler_tlast,
            prog_full_flag => out_arp_fifo_full,
            
            conf_mac => conf_mac,
            conf_ip  => conf_ip  
        );

    arp_fifo : xpm_fifo_axis
        generic map(
            CLOCKING_MODE    => "common_clock",
            FIFO_MEMORY_TYPE => "auto",
            CASCADE_HEIGHT   => 0,
            PACKET_FIFO      => "true",
            FIFO_DEPTH       => 512,
            TDATA_WIDTH      => 64,
            TID_WIDTH        => 1,
            TDEST_WIDTH      => 1,
            TUSER_WIDTH      => 1,
            ECC_MODE         => "no_ecc",
            RELATED_CLOCKS   => 0,
            USE_ADV_FEATURES => "0002",
            
            WR_DATA_COUNT_WIDTH => 1,
            RD_DATA_COUNT_WIDTH => 1,
            PROG_FULL_THRESH    => 496,
            PROG_EMPTY_THRESH   => 10,
            SIM_ASSERT_CHK      => 0,
            CDC_SYNC_STAGES     => 2
        )
        port map(
            s_aclk => clk,
            m_aclk => clk,
            s_aresetn => rstn_sync,
            
            -- input
            s_axis_tdata  => out_arp_handler_tdata,
            s_axis_tkeep  => out_arp_handler_tkeep,
            s_axis_tvalid => out_arp_handler_tvalid,
            s_axis_tlast  => out_arp_handler_tlast,
            s_axis_tready => out_arp_fifo_wready,
            -- not used
            s_axis_tstrb => (others => '1'),
            s_axis_tid   => (others => '0'),
            s_axis_tdest => (others => '0'),
            s_axis_tuser => (others => '0'),

            -- output
            m_axis_tdata   => out_arp_fifo_tdata,
            m_axis_tkeep   => out_arp_fifo_tkeep,
            m_axis_tvalid  => out_arp_fifo_tvalid,
            m_axis_tlast   => out_arp_fifo_tlast,
            m_axis_tready  => out_arp_fifo_tready,
            prog_full_axis => out_arp_fifo_full,

            --not used
            m_axis_tuser => open ,
            m_axis_tstrb => open,
            m_axis_tid   => open,
            m_axis_tdest => open,

            -- flags (disabled)
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

    priority_handler : entity work.axis_priority_handler
        port map(
            clk  => clk,
            rstn => rstn_sync,

            -- priority axis input
            s0_axis_tdata  => out_arp_fifo_tdata,
            s0_axis_tkeep  => out_arp_fifo_tkeep,
            s0_axis_tvalid => out_arp_fifo_tvalid,
            s0_axis_tlast  => out_arp_fifo_tlast,
            s0_axis_tready => out_arp_fifo_tready,

            -- non-priority axis input        
            s1_axis_tdata  => out_tx_fifo_tdata,
            s1_axis_tkeep  => out_tx_fifo_tkeep,
            s1_axis_tvalid => out_tx_fifo_tvalid,
            s1_axis_tlast  => out_tx_fifo_tlast,
            s1_axis_tready => out_tx_fifo_tready,

            -- output
            m_axis_tdata  => out_priority_tdata,
            m_axis_tkeep  => out_priority_tkeep,
            m_axis_tvalid => mac_tx_tvalid,
            m_axis_tlast  => mac_tx_tlast,
            m_axis_tready => mac_tx_tready
        );

    tx_endi : entity work.endianness_converter
        port map(
            tdata_in  => out_priority_tdata,
            tkeep_in  => out_priority_tkeep,
            tdata_out => mac_tx_tdata,
            tkeep_out => mac_tx_tkeep
        );


end architecture;