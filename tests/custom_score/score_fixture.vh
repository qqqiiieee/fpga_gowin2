// Test-only uploader fixture; five notes, two equal-pitch quarter notes,
// one rest quarter, a long continuation, and half a beat of silent padding.
function [31:0] fixture_word;
    input integer bank,q;
    integer note,step,v,onset,longnote,nextnote,nextvalid;
    begin
        note=0;step=0;v=0;onset=0;longnote=0;nextvalid=1;
        nextnote=bank ? 62 : 60;
        case(q)
            8:begin note=bank?62:60;v=1;onset=1;end
            9:begin note=bank?62:60;step=1;v=1;onset=1;nextnote=bank?65:64;end
            10:begin step=1;nextnote=bank?65:64;end
            11:begin note=bank?65:64;step=2;v=1;onset=1;nextnote=bank?69:67;end
            12,13,14,15:begin note=bank?69:67;step=3;v=1;
                onset=q==12;longnote=1;nextnote=bank?69:67;end
            16,17:begin note=bank?69:67;step=4;v=1;onset=q==16;nextvalid=0;end
            default:begin if(q>=18)begin step=4;nextvalid=0;end end
        endcase
        fixture_word=(32'h7f<<24)|(nextvalid<<23)|(nextnote<<16)|
                     (longnote<<15)|(onset<<14)|(v<<13)|(step<<7)|note;
    end
endfunction
function [31:0] fixture_config;
    input integer bank,spb;
    begin fixture_config=(bank<<31)|(1<<30)|(5<<24)|(5<<18)|spb;end
endfunction
