// Independent scalar oracles for the shared SIMD filters. Keep the recurrence
// explicit: this checks outputs, carried state and accumulation across calls.
#include "AnalysisKernels.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void near(double actual, double expected, double tolerance) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance * fmax(1.0, fabs(expected))) ++failures;
}
static void weighting(void) {
    const double c[10] = {1.53512485958697,-2.69169618940638,1.19839281085285,
        -1.69065929318241,0.73248077421585,1,-2,1,-1.99004745483398,0.99007225036621};
    const unsigned sizes[] = {0,1,7,64,257,1024,3};
    float audio[16][1024]; const float *input[16];
    for (unsigned lane = 0; lane < 16; ++lane) input[lane] = audio[lane];
    for (unsigned channels = 0; channels <= 16; ++channels) {
        double state[16][4] = {{0}}, reference[16][4] = {{0}}, energy[16] = {0}, expected[16] = {0};
        double *states[16];
        for (unsigned lane = 0; lane < 16; ++lane) {
            states[lane] = state[lane];
            energy[lane] = expected[lane] = 0.13 * lane;
        }
        for (unsigned block = 0; block < 140; ++block) {
            unsigned count = sizes[block % 7];
            for (unsigned lane = 0; lane < channels; ++lane) {
                double sum = 0, *s = reference[lane];
                for (unsigned i = 0; i < count; ++i) {
                    float x = block > 90 ? 0 : (float)(0.3*sin((i+block*1024)*(0.02+lane*0.07)) + 0.1*cos(i*0.8));
                    audio[lane][i] = x;
                    double y = c[0]*x + s[0];
                    s[0] = c[1]*x - c[3]*y + s[1]; s[1] = c[2]*x - c[4]*y;
                    double z = c[5]*y + s[2];
                    s[2] = c[6]*y - c[8]*z + s[3]; s[3] = c[7]*y - c[9]*z;
                    sum += z*z;
                }
                expected[lane] += sum;
            }
            k_weight_energy(c, states, input, channels, count, energy);
            for (unsigned lane = 0; lane < 16; ++lane) {
                near(energy[lane], expected[lane], 1e-10);
                for (unsigned j = 0; j < 4; ++j) near(state[lane][j], reference[lane][j], 1e-10);
            }
        }
    }
}
static void bands(void) {
    float c[3*4*5*4] = {0}, coeff[12][4][5];
    for (unsigned lane=0; lane<12; ++lane) for(unsigned section=0; section<4; ++section) {
        float values[5] = {0.2f+0.01f*lane,0.1f,0.2f,-0.7f+0.04f*section,0.2f};
        for(unsigned j=0;j<5;++j) c[((lane/4*4+section)*5+j)*4+lane%4] = coeff[lane][section][j] = values[j];
    }
    float left[257],right[257];
    for(unsigned lanes=0;lanes<=12;++lanes) {
        float state[3*4*2*4]={0},ref[12][4][2]={0},out[12][257],*outputs[12];
        for(unsigned l=0;l<12;++l)outputs[l]=out[l];
        for(unsigned block=0;block<50;++block) {
            unsigned count=block%3==0?0:block%3==1?7:257;
            for(unsigned l=0;l<12;++l)for(unsigned i=0;i<257;++i)out[l][i]=99;
            for(unsigned i=0;i<count;++i){left[i]=block>30?0:(float)sin((block*257+i)*0.03);right[i]=(float)cos((block*257+i)*0.3);}
            band_filter(c,state,left,right,outputs,lanes,count);
            for(unsigned lane=0;lane<12;++lane) {
                for(unsigned i=0;i<count;++i) {
                    float x=lane%2?right[i]:left[i];
                    for(unsigned k=0;k<4;++k) {
                        float *cf=coeff[lane][k], *s=ref[lane][k];
                        float y=cf[0]*x+s[0];s[0]=cf[1]*x-cf[3]*y+s[1];s[1]=cf[2]*x-cf[4]*y;x=y;
                    }
                    near(out[lane][i],lane<lanes?x:99,2e-6);
                }
                for(unsigned i=count;i<257;++i)near(out[lane][i],99,0);
                for(unsigned k=0;k<4;++k)for(unsigned j=0;j<2;++j)
                    near(state[((lane/4*4+k)*2+j)*4+lane%4],ref[lane][k][j],2e-6);
            }
        }
    }
}
int main(void) {
    weighting(); bands();
    printf("%s: scalar/SIMD kernels, all lane counts, irregular/empty buffers, silence tails, state and output guards (%d failures)\n", failures?"FAIL":"PASS",failures);
    return failures?1:0;
}
