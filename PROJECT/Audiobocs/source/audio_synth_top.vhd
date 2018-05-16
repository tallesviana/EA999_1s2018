---------------------------------------------------------
------------    AUDIO SYNTH TOP ENTITY
---------------------------------------------------------
-- 15/05/18 - tallesvv
---------------------------------------------------------

LIBRARY ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

LIBRARY work;  -- Able to see the other components

------------------------------------------------------
-->>>>>>>>>>>      ENTITY DECLARATION   <<<<<<<<<<<<<<
------------------------------------------------------

ENTITY audio_synth_top IS
    PORT(
        CLOCK_50 :  IN std_logic;
        KEY      :  IN std_logic_vector(3 downto 0);
        SW       :  IN std_logic_vector(9 downto 0);

        DACDAT_gL:  IN std_logic_vector(15 downto 0); -- Generated signal -- Temporary
        DACDAT_gR:  IN std_logic_vector(15 downto 0);

        AUD_XCK  :  OUT std_logic;
        I2C_SCLK :  OUT std_logic;
        I2C_SDAT :  INOUT std_logic;

        AUD_ADCDAT :  IN std_logic;
        AUD_DACDAT :  OUT std_logic;

        AUD_BCLK    :  OUT std_logic;
        AUD_DACLRCK :  OUT std_logic;
        AUD_ADCLRCK :  OUT std_logic
    );
END audio_synth_top;

------------------------------------------------------
-->>>>>>>>>>>      COMPONENTS USED      <<<<<<<<<<<<<<
------------------------------------------------------

ARCHITECTURE top OF audio_synth_top IS

COMPONENT codec_ctrl IS
    PORT(
        event_ctrl_i :  IN std_logic_vector(2 downto 0);
        init_i       :  in std_logic;
        write_done_i :  IN std_logic;
        ack_error_i  :  IN std_logic;
        clk          :  IN std_logic;
        reset_n      :  IN std_logic;

        write_o      :  OUT std_logic;
        write_data_o :  OUT std_logic_vector(15 downto 0)
    );
END COMPONENT;

COMPONENT i2c_master is
        port(
            clk         : in    std_logic;
            reset_n     : in    std_logic;

            write_i     : in    std_logic;
			write_data_i: in	std_logic_vector(15 downto 0);
			
			sda_io		: inout	std_logic;
			scl_o		: out   std_logic;
			
			write_done_o: out	std_logic;
			ack_error_o	: out	std_logic
        );
end COMPONENT;

COMPONENT audio_ctrl IS
    PORT(
        clk_12M      :  IN std_logic;
        reset_n_12M  :  IN std_logic;
        init_n   :  IN std_logic;

        -- SW(0) -> Filter? (1-Y, 0-N)     SW(1) -> Data flow (1-ADC, 0-Generated)
        sw_cfg_i :  IN std_logic_vector(1 downto 0);  -- Selects if data going to filter Datagen or DataADC
        
        strobe :  IN std_logic;

        ADCDAT_pl_i: IN std_logic_vector(15 downto 0);
        ADCDAT_pr_i: IN std_logic_vector(15 downto 0);

        DACDAT_gen_pl_i: IN std_logic_vector(15 downto 0);
        DACDAT_gen_pr_i: IN std_logic_vector(15 downto 0);


        DACDAT_pl_o: OUT std_logic_vector(15 downto 0);
        DACDAT_pr_o: OUT std_logic_vector(15 downto 0);

        init_o     : OUT std_logic
    );
END COMPONENT;

COMPONENT i2s_master IS 
    PORT(
        clk_12M  :  IN std_logic;
        reset_n  :  IN std_logic;

        DACDAT_pr_i  :  IN std_logic_vector(15 downto 0); -- Parallel signal input from filters
        DACDAT_pl_i  :  IN std_logic_vector(15 downto 0);
        ADCDAT_s_i   :  IN std_logic;  -- Serial ADC IN from WM8731

        ADCDAT_pr_o  :  OUT std_logic_vector(15 downto 0); -- Parallel signal out to filters
        ADCDAT_pl_o  :  OUT std_logic_vector(15 downto 0);
        DACDAT_s_o   :  OUT std_logic;  -- Serial DAC OUT to WM8731

        INIT_N       :  IN std_logic;  -- Key to init
        STROBE_o     :  OUT std_logic; -- Load
        BCLK_o       :  OUT std_logic; 
        WS_o         :  OUT std_logic -- ADCLRCK and DACLRCK
    );
END COMPONENT;

COMPONENT clock_div IS
    PORT(
        clk_fast_i :  IN std_logic;
        clk_slow_o :  OUT std_logic
    );
END COMPONENT;

COMPONENT sync_block IS
    PORT(
        async_i:  IN std_logic;
        clk:      IN std_logic;

        syncd_o:   OUT std_logic
    );
END COMPONENT;

------------------------------------------------------
-->>>>>>>>>>>      SIGNAL DECLARATION   <<<<<<<<<<<<<<
------------------------------------------------------

SIGNAL t_clock_50   :  std_logic;  -- Input clock - 50MHz
SIGNAL t_clock_12_5 :  std_logic;  -- Sys clock   - 12,5MHz
SIGNAL t_key        :  std_logic_vector(3 downto 0);  -- Input keys
SIGNAL t_sw         :  std_logic_vector(9 downto 0);  -- Input toggle switches

SIGNAL t_reset_syncd      :  std_logic;  -- Key signals after syncing - RESET
SIGNAL t_init_codec_syncd :  std_logic;  -- INIT CODEC CTRL
SIGNAL t_init_audio_syncd :  std_logic;  -- INIT AUDIO CTRL

SIGNAL t_write_done :  std_logic;  -- Feedback signals
SIGNAL t_ack_error  :  std_logic;

SIGNAL t_write      : std_logic;  -- Signals from Codec Ctrl to I2C Master
SIGNAL t_data2write : std_logic_vector(15 downto 0);

SIGNAL t_i2c_sclk   : std_logic;  -- Output signals from I2C Master

SIGNAL t_dacdat_pl  : std_logic_vector(15 downto 0);  -- I2S and AudioCtrl signals
SIGNAL t_dacdat_pr  : std_logic_vector(15 downto 0);

SIGNAL t_adcdat_pl  : std_logic_vector(15 downto 0);
SIGNAL t_adcdat_pr  : std_logic_vector(15 downto 0);

SIGNAL t_strobe     : std_logic;
SIGNAL t_ws         : std_logic;
SIGNAL t_init_audioctrl2i2s : std_logic;

------------------------------------------------------
-->>>>>>>>>>>      BEGIN OF ARCHITEC   <<<<<<<<<<<<<<
------------------------------------------------------

BEGIN


clk_div_1: clock_div                        --  CLOCK DIVIDER
    PORT MAP(
        clk_fast_i => t_clock_50,
        clk_slow_o => t_clock_12_5
    );

reset_sync: sync_block                      --  RESET SINC 
    PORT MAP(
        async_i => t_key(0),
        clk     => t_clock_12_5,
        syncd_o => t_reset_syncd
    );

init_codec_sync: sync_block                 -- INIT CODEC CTRL SINC
    PORT MAP(
        async_i => t_key(1),
        clk     => t_clock_12_5,
        syncd_o => t_init_codec_syncd
    );

init_audio_sync: sync_block                 -- INIT AUDIO CTRL SINC
    PORT MAP(       
        async_i => t_key(2),
        clk     => t_clock_12_5,
        syncd_o => t_init_audio_syncd
    );

codec: codec_ctrl                           --  CODEC CONTROLLER
    PORT MAP(
        event_ctrl_i => t_sw(2 downto 0),
        init_i       => t_init_codec_syncd,
        write_done_i => t_write_done,
        ack_error_i  => t_ack_error,
        clk          => t_clock_12_5,
        reset_n      => t_reset_syncd,
        write_o      => t_write,
        write_data_o => t_data2write
    );

master: i2c_master                          -- I2C MASTER
    PORT MAP(
        clk         => t_clock_12_5,
        reset_n     => t_reset_syncd,

        write_i     => t_write,
        write_data_i=> t_data2write,
        
        sda_io		=> I2C_SDAT,  -- Connected I2C SDA directly
        scl_o		=> t_i2c_sclk,
        
        write_done_o=> t_write_done,
        ack_error_o	=> t_ack_error
    );

audio:  audio_ctrl                                  -- AUDIO CONTROLLER
    PORT MAP(
        clk_12M      => t_clock_12_5,
        reset_n_12M  => t_reset_syncd,
        init_n       => t_init_audio_syncd,
        sw_cfg_i     => t_sw(1 downto 0),
        strobe       => t_strobe,

        ADCDAT_pl_i  => t_adcdat_pl,
        ADCDAT_pr_i  => t_adcdat_pr,

        DACDAT_gen_pl_i  => DACDAT_gL,             -- Temporary signals
        DACDAT_gen_pr_i  => DACDAT_gR,

        DACDAT_pl_o  => t_dacdat_pl,
        DACDAT_pr_o  => t_dacdat_pr,

        init_o       => t_init_audioctrl2i2s
    );

i2s: i2s_master                                     -- I2S MASTER BLOCK
    PORT MAP(
        clk_12M  => t_clock_12_5,
        reset_n  => t_reset_syncd,

        DACDAT_pr_i  => t_dacdat_pl,
        DACDAT_pl_i  => t_dacdat_pr,
        ADCDAT_s_i   => AUD_ADCDAT,

        ADCDAT_pr_o  => t_adcdat_pl,
        ADCDAT_pl_o  => t_adcdat_pr,
        DACDAT_s_o   => AUD_DACDAT,

        INIT_N       => t_init_audioctrl2i2s,
        STROBE_o     => t_strobe,
        BCLK_o       => AUD_BCLK,
        WS_o         => t_ws
    );


t_clock_50 <= CLOCK_50;
t_key      <= KEY;
t_sw       <= SW;
AUD_XCK    <= t_clock_12_5;
I2C_SCLK   <= t_i2c_sclk;

AUD_ADCLRCK <= t_ws;
AUD_DACLRCK <= t_ws;

END top;
