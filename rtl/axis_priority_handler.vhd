-- Written by Yuval Peleg & Aylon Feraru Jun.2026
-- sorts out the priority of the incoming data of two axis streams in packet mode
-- prioritizing one over the other.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_priority_handler is
    port (
        clk, rstn : in std_logic;

        -- priority axis input
        s0_axis_tdata  : in std_logic_vector(63 downto 0);
        s0_axis_tkeep  : in std_logic_vector(7 downto 0);
        s0_axis_tvalid : in std_logic;
        s0_axis_tlast  : in std_logic;
        s0_axis_tready : out std_logic;

        -- non-priority axis input        
        s1_axis_tdata  : in std_logic_vector(63 downto 0);
        s1_axis_tkeep  : in std_logic_vector(7 downto 0);
        s1_axis_tvalid : in std_logic;
        s1_axis_tlast  : in std_logic;
        s1_axis_tready : out std_logic;


        -- AXI-S out 
        m_axis_tdata  : out std_logic_vector(63 downto 0);
        m_axis_tkeep  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tid    : out std_logic;
        m_axis_tready : in std_logic
    );
end axis_priority_handler;

architecture rtl of axis_priority_handler is

    constant AXIS0 : std_logic := '0'; 
    constant AXIS1 : std_logic := '1'; 

    type state_type is (idle, transmitting);
    signal state : state_type := idle;

    signal chosen_axis        : std_logic := AXIS0;
    signal chosen_axis_buffer : std_logic := AXIS0;

begin

    -- combinational so no delay
    chosen_axis <= AXIS0 when(state = idle and s0_axis_tvalid = '1') else
                   AXIS1 when(state = idle and s1_axis_tvalid = '1') else
                   chosen_axis_buffer;

    process(clk, rstn)
    begin
        if(rising_edge(clk)) then
            if(rstn = '0') then
                state <= idle;
                chosen_axis_buffer <= AXIS0;
            else
                case state is
                    when idle  =>
                        if (s0_axis_tvalid = '1' or s1_axis_tvalid = '1') then
                            chosen_axis_buffer <= chosen_axis;

                            if ((chosen_axis = AXIS0 and not(s0_axis_tlast = '1' and m_axis_tready = '1')) or
                                (chosen_axis = AXIS1 and not(s1_axis_tlast = '1' and m_axis_tready = '1'))) then
                                state <= transmitting; 
                            end if;
                        end if; 

                    when transmitting => 
                        -- never switches streams in the middle of transmissions 
                        -- waits until tlast and tready to reevaluate priorities. 
                        if ((chosen_axis_buffer = AXIS0 and s0_axis_tvalid = '1' and s0_axis_tlast = '1')  or  
                            (chosen_axis_buffer = AXIS1 and s1_axis_tvalid = '1' and s1_axis_tlast = '1')) and
                            m_axis_tready = '1' then 
                            state <= idle;
                        end if;
        
                end case; 
            end if;
        end if;
    end process;

    -- instantaneous switching of streams
    m_axis_tdata  <= s0_axis_tdata  when(chosen_axis = AXIS0) else s1_axis_tdata; 
    m_axis_tkeep  <= s0_axis_tkeep  when(chosen_axis = AXIS0) else s1_axis_tkeep;
    m_axis_tvalid <= s0_axis_tvalid when(chosen_axis = AXIS0) else s1_axis_tvalid;
    m_axis_tlast  <= s0_axis_tlast  when(chosen_axis = AXIS0) else s1_axis_tlast;
    m_axis_tid    <= chosen_axis;
    
    s0_axis_tready <= m_axis_tready when(chosen_axis = AXIS0) else '0';
    s1_axis_tready <= m_axis_tready when(chosen_axis = AXIS1) else '0';

end architecture;