      program main
      use parameters
      use init
      use pbc
      use integraforces
      use statvis
      use rad_dist
  
      implicit none
      include 'mpif.h'
      character(len=50)   :: input_name
      real*8, allocatable :: pos(:,:), vel(:,:), fold(:,:), g_avg(:), g_squared_avg(:), g_avg_final(:), g_squared_avg_final(:)
      real*8, allocatable :: pos_local(:,:),vel_local(:,:),vec(:)
      real*8, allocatable :: epotVECins(:), epotVEC(:), PVEC(:), ekinVEC(:), etotVEC(:), TinsVEC(:)
      real*8, allocatable :: Xpos(:), Ypos(:), Zpos(:), posAUX(:,:), noPBC(:,:)
      
      real*8              :: time,ekin,epot,Tins,P,etot,epot_local,P_local
      real*8              :: epotAUX,epotMEAN,PMEAN,epotVAR,PVAR
      real*8              :: ekinMEAN,ekinVAR,etotMEAN,etotVAR,TinsMEAN,TinsVAR
      real*8              :: Xmean,Ymean,Zmean,Xvar,Yvar,Zvar
      integer             :: i,j,ierror,request,Nshells,flag_g,k,cnt
      real*8              :: ti_global,tf_global,elapsed_time !AJ: collective timing of program.
      
      ! Init MPI
      call MPI_INIT(ierror)
      call MPI_COMM_RANK(MPI_COMM_WORLD,taskid,ierror)
      call MPI_COMM_SIZE(MPI_COMM_WORLD,numproc,ierror)
      ti_global = MPI_WTIME()

      allocate(aux_pos(numproc))
      allocate(aux_size(numproc))
  
      ! To execute the program >> main.x input_file. Otherwise, an error will occur.
      if (command_argument_count() == 0) stop "ERROR: call using >> ./main.x input_path"
      call get_command_argument(1, input_name)
      
      ! Open and read input 
      open(unit=10, file=input_name)
      call get_param(10)
      close(10)
  
      ! Allocates
      allocate(pos(D,N))
      allocate(vel(D,N)) 
      allocate(pos_local(D,N))
      allocate(vel_local(D,N)) 
      allocate(vec(N))
      allocate(fold(D,N))
      allocate(epotVECins(n_meas))
      allocate(PVEC(n_conf))
      allocate(ekinVEC(n_conf))
      allocate(epotVEC(n_conf))
      allocate(etotVEC(n_conf))
      allocate(TinsVEC(n_conf))
      allocate(Xpos(N))
      allocate(Ypos(N))
      allocate(Zpos(N))
      allocate(posAUX(D,N))
      allocate(noPBC(D,N))
      
      if(taskid==master) then
            call execute_command_line('clear')
            print*,"------------------------Parameters-------------------------------"
            print"(A,X,I5,2X,A,X,I1)", "N=",N,"D=",D
            print"(A,X,E14.7)","dt_sim=",dt_sim
            print"(A,X,I8)","seed=",seed
            print"(A,X,F4.2,2X,A,X,F6.2)","rho=",rho,"T=",T_ref
            print"(A,X,F10.5,2X,A,X,F10.5,2X,A,X,F10.5)","eps=",epsilon,"sigma=",sigma,"rc=",rc
            print"(A,X,I10)","n_equil=",n_equil
            print"(A,X,I3,2X,I10,2X,I10)","n_meas,n_conf,n_total=",n_meas,n_conf,n_total
            print*,"-----------------------------------------------------------------"
      end if
      call MPI_BARRIER(MPI_COMM_WORLD,ierror) 
  
      ! Initialize positions and velocities
      call init_sc(pos)
      call init_vel(vel, 10.d0)
      ! pos_local = 0.d0
      ! vel_local = 0.d0
      do i=1,D
            vec = pos(i,:)
            call MPI_BCAST(vec,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request,ierror)
            pos_local(i,:) = vec
      end do
      do i=1,D
            vec = vel(i,:)
            call MPI_BCAST(vec,N,MPI_DOUBLE_PRECISION,master,MPI_COMM_WORLD,request,ierror)
            vel_local(i,:) = vec
      end do

      do j = 1, D
            call MPI_Gatherv(pos_local(j,imin:imax), local_size, MPI_DOUBLE_PRECISION, pos(j,:), &
                            aux_size, aux_pos, MPI_DOUBLE_PRECISION, master, &
                            MPI_COMM_WORLD, ierror)
      end do
  
      !Start melting
      if(taskid==master) then
            open(unit=10,file="results/thermodynamics_initialization.dat")
            open(unit=12,file="results/dimensionalized/thermodynamics_initialization_dim.dat") 
            open(unit=11,file="results/init_conf.xyz")
            call writeXyz(D,N,pos,11)
      end if

      flag_g = 0
      if(taskid==master)print*,"------Melting Start------"
      call vvel_solver(5000,1.d-4,pos_local,vel_local,1000.d0,10,12,0,0,flag_g)
      ! if(taskid==2) then
      !       do j=imin,imax
      !             print*,pos_local(:,j)
      !       end do
      ! end if
      do j = 1, D
            call MPI_Gatherv(pos_local(j,imin:imax), local_size, MPI_DOUBLE_PRECISION, pos(j,:), &
                            aux_size, aux_pos, MPI_DOUBLE_PRECISION, master, &
                            MPI_COMM_WORLD, ierror)
      end do
      if(taskid==master)call writeXyz(D,N,pos,11) !Check that it is random.
      if(taskid==master) then
        call execute_command_line('echo -e "\033[2A"')
        print*,"------Melting Completed------"
      endif
      !End melting

      ! Start dynamics
      ! Perform equilibration of the system
      call init_vel(vel_local, T_ref) ! Reescale to target temperature

      if(taskid==master) then
            close(10)
            close(11)
            close(12)
            open(unit=10,file="results/thermodynamics_equilibration.dat")
            open(unit=11,file="results/dimensionalized/thermodynamics_equilibration_dim.dat")
      end if

      if(taskid==master)print*,"------Equilibration Start------"
      call vvel_solver(n_equil,dt_sim,pos_local,vel_local,T_ref,10,11,0,0,flag_g)
      if(taskid==master) then
        call execute_command_line('echo -e "\033[2A"')
        print*,"------Equilibration Completed------"
      endif
   
      !Prepare files for main simulation   
      if(taskid==master) then
            close(10)
            close(11)
            open(unit=10,file="results/thermodynamics.dat")
            open(unit=11,file="results/trajectory.xyz")
            open(unit=12,file="results/radial_distribution.dat")
            open(unit=13,file="results/mean_epot.dat")
            open(unit=14,file="results/diffcoeff.dat")
            open(unit=15,file="results/averages.dat")
            open(unit=22,file="results/ekinBIN.dat")
            open(unit=23,file="results/epotBIN.dat")
            open(unit=24,file="results/correlation_energy.dat")

            open(unit=16,file="results/dimensionalized/thermodynamics_dim.dat")
            open(unit=17,file="results/dimensionalized/trajectory_dim.xyz")
            open(unit=18,file="results/dimensionalized/mean_epot_dim.dat")
            open(unit=19,file="results/dimensionalized/diffcoeff_dim.dat")
            open(unit=20,file="results/dimensionalized/averages_dim.dat")
            open(unit=21,file="results/dimensionalized/radial_distribution_dim.dat")
            open(unit=25,file="results/dimensionalized/ekinBIN_dim.dat")
            open(unit=26,file="results/dimensionalized/epotBIN_dim.dat")
            open(unit=27,file="results/dimensionalized/correlation_energy_dim.dat")
      
            write(10,*)"#t,   K,   U,  E,  T,  v_tot,  Ptot"
            write(16,*)"#t,   K,   U,  E,  T,  Ptot"
      end if
  
      ! Prepare g(r) variables
      Nshells = 100
      call prepare_shells(Nshells)
      allocate(g_avg(Nshells))
      allocate(g_squared_avg(Nshells))
      g_avg = 0d0
      g_squared_avg = 0d0
      if(taskid==master) then
            allocate(g_avg_final(Nshells))
            allocate(g_squared_avg_final(Nshells))       
      endif
      
      if(taskid==master) then
            print*,"------Simulation Start------"
      endif
      
      k = 0
      cnt = 0
      epotAUX = 0.d0
      noPBC = 0.d0
      
      call compute_force_LJ(pos_local,fold,epot_local,P_local)
      do i = 1,n_total

	    posAUX = pos
      
            call verlet_v_step(pos_local,vel_local,fold,time,i,dt_sim,epot_local,P_local)
            call andersen_therm(vel_local,T_ref)
            
	!     do j=1,N
	! 	  ! X
	!           if ((pos(1,j)-posAUX(1,j)).gt.(0.9d0*L)) then
	! 	        noPBC(1,j) = noPBC(1,j) - L
	! 	  elseif ((pos(1,j)-posAUX(1,j)).lt.(0.9d0*L)) then
	! 	        noPBC(1,j) = noPBC(1,j) + L
	! 	  endif
	! 	  ! Y
	!           if ((pos(2,j)-posAUX(2,j)).gt.(0.9d0*L)) then
	! 	        noPBC(2,j) = noPBC(2,j) - L
	! 	  elseif ((pos(2,j)-posAUX(2,j)).lt.(0.9d0*L)) then
	! 	        noPBC(2,j) = noPBC(2,j) + L
	! 	  endif
	! 	  ! Z
	!           if ((pos(3,j)-posAUX(3,j)).gt.(0.9d0*L)) then
	! 	        noPBC(3,j) = noPBC(3,j) - L
	! 	  elseif ((pos(3,j)-posAUX(3,j)).lt.(0.9d0*L)) then
	! 	        noPBC(3,j) = noPBC(3,j) + L
	! 	  endif
      !       enddo
      !       ! Càlcul del coeficient de difusió per cada dimensió
      !       Xpos(:) = pos(1,:) + noPBC(1,:)
      !       Ypos(:) = pos(2,:) + noPBC(2,:)
      !       Zpos(:) = pos(3,:) + noPBC(3,:)
      !       call estad(N,Xpos,Xmean,Xvar)
      !       call estad(N,Ypos,Ymean,Yvar)
      !       call estad(N,Zpos,Zmean,Zvar)
      !       if (taskid.eq.master) then
      !           write(14,*) 2.d0*dble(i), Xvar*dble(N), Yvar*dble(N), Zvar*dble(N)
      !           write(19,*) 2.d0*time, Xvar*dble(N)*unit_of_length**2,&
      !            Yvar*dble(N)*unit_of_length**2,&
      !            Zvar*dble(N)*unit_of_length**2
      !       endif

            ! k = k+1
            ! call MPI_REDUCE(epot_local,epot,1,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)
            ! epotVECins(k) = epot
      
            if(mod(i,n_meas) == 0) then ! AJ : measure every n_meas steps
                  do j = 1, D
                        call MPI_Gatherv(pos_local(j,imin:imax), local_size, MPI_DOUBLE_PRECISION, pos(j,:), &
                                        aux_size, aux_pos, MPI_DOUBLE_PRECISION, master, &
                                        MPI_COMM_WORLD, ierror)
                  end do
            !       call MPI_REDUCE(P_local,P,1,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)
            !       ! Average de epot cada n_meas. Ho escribim en un fitxer
            !       k = 0
            !       cnt = cnt+1
            !       call estad(n_meas,epotVECins,epotMEAN,epotVAR)
            !       if (taskid.eq.master) then
            !             epotAUX = (epotMEAN+epotAUX*dble(cnt-1))/dble(cnt)
            !             write(13,*) i, epotAUX
            !             write(18,*) i, epotAUX*unit_of_energy
            !       endif
                  
            !       call energy_kin(vel,ekin,Tins)
                  if(taskid==master) then
            !             write(10,*) time, ekin, epot, ekin+epot, Tins, dsqrt(sum(sum(vel,2)**2)), P+rho*Tins
            !             write(16,*) time*unit_of_time,&
            !             ekin*unit_of_energy, epot*unit_of_energy, (ekin+epot)*unit_of_energy,&
            !             Tins*epsilon, (P+rho*Tins)*unit_of_pressure
            !             ekinVEC(cnt) = ekin
            !             epotVEC(cnt) = epot
            !             etotVEC(cnt) = ekin+epot
            !             TinsVEC(cnt) = Tins
            !             PVEC(cnt) = P+rho*Tins
                        call writeXyz(D,N,pos,11)
            !             call writeXyz(D,N,pos*unit_of_length,17)
                  end if
                   ! each processor computes its part of the g(r) and saves its contribution to the average: 
                   call rad_dist_fun_pairs_improv(pos,Nshells)
                   g_avg = g_avg + g
                   g_squared_avg = g_squared_avg + g**2
            endif
      
            if(mod(i,int(0.001*n_total))==0 .and. taskid==master) then
                  write (*,"(A,F5.1,A)",advance="no") "Progress: ",i/dble(n_total)*100.,"%"
                  if (i.le.n_total) call execute_command_line('echo -e "\033[A"')
            endif
      enddo
      
      ! if(taskid==master) then
      !       write (*,*)
      !       call execute_command_line('echo -e "\033[3A"')
      !       write (*,*) "----Simulation Completed----"
      !       close(10)
      !       close(11)
      !       close(13)
      !       close(14)

      !       close(16)
      !       close(17)
      !       close(18)
      !       close(19)
      ! end if
      
      ! ! Average de la g(r)
      call MPI_REDUCE(g_avg,g_avg_final,Nshells,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)
      call MPI_REDUCE(g_squared_avg,g_squared_avg_final,Nshells,MPI_DOUBLE_PRECISION,MPI_SUM,master,MPI_COMM_WORLD,ierror)
      if(taskid==master) then
             g_avg_final = g_avg_final/dble(n_conf)
             g_squared_avg_final = g_squared_avg_final/dble(n_conf)
             !g_avg = g_avg/dble(n_conf)
             !g_squared_avg = g_squared_avg/dble(n_conf)
             write(12,*) " # r (reduced units),   g(r),   std_dev "
             write(21,*) " # r (Angstroms),   g(r),    std_dev"
             do i=1,Nshells
                   write(12,*) grid_shells*(i-1)+grid_shells/2d0, g_avg_final(i), dsqrt(g_squared_avg_final(i) - g_avg_final(i)**2)
                   write(21,*) grid_shells*(i-1)*sigma + grid_shells*sigma/2d0, &
                               g_avg_final(i), dsqrt(g_squared_avg_final(i) - g_avg_final(i)**2)
             !      write(12,*) grid_shells*(i-1)+grid_shells/2d0, g_avg(i), dsqrt(g_squared_avg(i) - g_avg(i)**2)
             !      write(21,*) grid_shells*(i-1)*sigma + grid_shells*sigma/2d0, g_avg(i), dsqrt(g_squared_avg(i) - g_avg(i)**2)
             enddo
             close(12)
             close(21)
       endif

      ! ! Averages finals
      ! if (allocated(epotVECins)) deallocate(epotVECins)

      ! call estad(n_conf,ekinVEC,ekinMEAN,ekinVAR)
      ! call estad(n_conf,epotVEC,epotMEAN,epotVAR)
      ! call estad(n_conf,etotVEC,etotMEAN,etotVAR)
      ! call estad(n_conf,TinsVEC,TinsMEAN,TinsVAR)
      ! call estad(n_conf,PVEC,PMEAN,PVAR)
      
      ! if (taskid.eq.master) then
      !     write(15,*) "Sample mean and Statistical error"
      !     write(15,*) "Kinetic Energy", ekinMEAN, dsqrt(ekinVAR)
      !     write(15,*) "Potential Energy", epotMEAN, dsqrt(epotVAR)
      !     write(15,*) "Total Energy", etotMEAN, dsqrt(etotVAR)
      !     write(15,*) "Instant Temperature", TinsMEAN, dsqrt(TinsVAR)
      !     write(15,*) "Pressure", PMEAN, dsqrt(PVAR)
      !     close(15)

      !     write(20,*) "Sample mean and Statistical error"
      !     write(20,*) "Kinetic Energy", ekinMEAN*unit_of_energy, dsqrt(ekinVAR)*unit_of_energy
      !     write(20,*) "Potential Energy", epotMEAN*unit_of_energy, dsqrt(epotVAR)*unit_of_energy
      !     write(20,*) "Total Energy", etotMEAN*unit_of_energy, dsqrt(etotVAR)*unit_of_energy
      !     write(20,*) "Instant Temperature", TinsMEAN*epsilon, dsqrt(TinsVAR)*epsilon
      !     write(20,*) "Pressure", PMEAN*unit_of_pressure, dsqrt(PVAR)*unit_of_pressure
      !     close(20)
      ! endif

      ! ! Binning de les energies cinètica i potencial
      ! call binning(n_conf,ekinVEC,50,22)
      ! call binning(n_conf,epotVEC,50,23)
      
      ! call binning(n_conf,ekinVEC*unit_of_energy,50,25)
      ! call binning(n_conf,epotVEC*unit_of_energy,50,26)
      
      ! ! Funció d'autocorrelació per l'energia total
      ! call corrtime(n_conf,etotVEC,24)
      ! call corrtime(n_conf,etotVEC*unit_of_energy,27)
      
      ! if (taskid.eq.master) then
      !   close(22)
      !   close(23)
      !   close(24)
        
      !   close(25)
      !   close(26)
      !   close(27)
      ! endif
  
  
      if (allocated(pos)) deallocate(pos)
      if (allocated(vel)) deallocate(vel)
      if (allocated(fold)) deallocate (fold)
      if (allocated(aux_pos)) deallocate(aux_pos)
      if (allocated(aux_size)) deallocate(aux_size)
      if (allocated(epotVEC)) deallocate(epotVEC)
      if (allocated(PVEC)) deallocate(PVEC)
      if (allocated(ekinVEC)) deallocate(ekinVEC)
      if (allocated(etotVEC)) deallocate(etotVEC)
      if (allocated(TinsVEC)) deallocate(TinsVEC)
      if (allocated(Xpos)) deallocate(Xpos)
      if (allocated(Ypos)) deallocate(Ypos)
      if (allocated(Zpos)) deallocate(Zpos)
      if (allocated(posAUX)) deallocate(posAUX)
      if (allocated(noPBC)) deallocate(noPBC)
      if (allocated(g_avg)) deallocate(g_avg)
      if (allocated(g_squared_avg)) deallocate(g_squared_avg)
      if (allocated(aux_size))allocate(aux_size(numproc))
      if (allocated(aux_pos))allocate(aux_pos(numproc))
      call deallocate_g_variables()
  
      tf_global = MPI_WTIME()
      call MPI_REDUCE(tf_global-ti_global,elapsed_time,1,MPI_DOUBLE_PRECISION,MPI_MAX,master,MPI_COMM_WORLD,ierror)
      if(taskid==master) then
            print"(A,X,F14.7,X,A)","End program, time elapsed:",elapsed_time,"seconds"
      end if
  
      call MPI_FINALIZE(ierror)
      end program main
  
