#pragma once
#include <Arduino.h>
#include <driver/uart.h>
#include <esp_intr_alloc.h>
#include <hal/uart_ll.h>
#include <soc/uart_periph.h>

// Classic ESP32 UART2 only. Arduino 2.0.17's bundled UART ISR is not IRAM-safe:
// LittleFS writes disable it and overflow the 128-byte FIFO at 1M baud. Merely
// increasing HardwareSerial's software ring cannot preserve these lost bytes.
// This receiver keeps the interrupt AND all accessed data in internal RAM.
// No allocator, driver callback, String, RTOS API or flash lookup runs in ISR.
// UART0/CH340 still uses normal HardwareSerial. No extra wires/flow-control pins.
class RecordingUart {
 static constexpr uint32_t SIZE=32768, MASK=SIZE-1;
 uint8_t ring[SIZE]{};
 volatile uint32_t wr=0,rd=0,errorCount=0,highWater=0;
 intr_handle_t handle=nullptr;bool ready=false;
 static void IRAM_ATTR receiveIsr(void* arg);

public:
 bool begin(unsigned baud,int rx,int tx){
  uart_config_t config={};config.baud_rate=baud;config.data_bits=UART_DATA_8_BITS;
  config.parity=UART_PARITY_DISABLE;config.stop_bits=UART_STOP_BITS_1;
  config.flow_ctrl=UART_HW_FLOWCTRL_DISABLE;config.source_clk=UART_SCLK_APB;
  if(uart_param_config(UART_NUM_2,&config)!=ESP_OK||uart_set_pin(UART_NUM_2,tx,rx,-1,-1)!=ESP_OK)return false;
  uart_ll_disable_intr_mask(&UART2,UART_LL_INTR_MASK);
  uart_ll_clr_intsts_mask(&UART2,UART_LL_INTR_MASK);
  // Allocate directly: IDF uart_isr_register() dereferences driver private state
  // and is not valid without uart_driver_install(), whose ISR we do not use.
  if(esp_intr_alloc(ETS_UART2_INTR_SOURCE,ESP_INTR_FLAG_IRAM|ESP_INTR_FLAG_LEVEL1,receiveIsr,this,&handle)!=ESP_OK)return false;
  uart_intr_config_t interrupts={};
  interrupts.intr_enable_mask=UART_INTR_RXFIFO_FULL|UART_INTR_RXFIFO_TOUT|UART_INTR_RXFIFO_OVF|UART_INTR_PARITY_ERR|UART_INTR_FRAM_ERR;
  interrupts.rxfifo_full_thresh=32;interrupts.rx_timeout_thresh=2;
  ready=uart_intr_config(UART_NUM_2,&interrupts)==ESP_OK;
  return ready;
 }
 unsigned available()const{return wr-rd;}
 uint32_t errors()const{return errorCount;}
 uint32_t high()const{return highWater;}
 size_t read(uint8_t* out,size_t amount){
  uint32_t r=rd,w=wr;__asm__ __volatile__("memw" ::: "memory");
  if(amount>w-r)amount=w-r;
  for(size_t i=0;i<amount;++i)out[i]=ring[(r+i)&MASK];
  // Publish reclaimed space only AFTER the consumer has copied all bytes.
  __asm__ __volatile__("memw" ::: "memory");rd=r+amount;return amount;
 }
 size_t write(const uint8_t* data,size_t count){
  if(!ready)return 0;
  size_t done=0;uint32_t began=millis();
  while(done<count){
   unsigned room=uart_ll_get_txfifo_len(&UART2); // returns FREE slots, not used.
   unsigned n=count-done;if(n>room)n=room;
   if(n){uart_ll_write_txfifo(&UART2,data+done,n);done+=n;}
   else {if(uint32_t(millis()-began)>50)return done;delay(1);}
  }
  return done;
 }
};

// Out-of-class definition avoids COMDAT literal placement outside IRAM.
void IRAM_ATTR RecordingUart::receiveIsr(void* arg){
  RecordingUart* p=static_cast<RecordingUart*>(arg);
  uart_dev_t* hw=&UART2;
  uint32_t status=uart_ll_get_intsts_mask(hw);
  uart_ll_clr_intsts_mask(hw,status);
  if(status&(UART_INTR_RXFIFO_OVF|UART_INTR_PARITY_ERR|UART_INTR_FRAM_ERR))++p->errorCount;
  uint32_t count=uart_ll_get_rxfifo_len(hw);
  uint32_t w=p->wr,r=p->rd;
  bool full=false;
  for(uint32_t i=0;i<count;++i){
   // LL reads the APB FIFO address (not the AHB TX alias).
   uint8_t byte;uart_ll_read_rxfifo(hw,&byte,1);
   if(w-r<SIZE){p->ring[w&MASK]=byte;++w;}else full=true;
  }
  if(full)++p->errorCount;
  if(w-r>p->highWater)p->highWater=w-r;
  __asm__ __volatile__("memw" ::: "memory");p->wr=w;
 }
